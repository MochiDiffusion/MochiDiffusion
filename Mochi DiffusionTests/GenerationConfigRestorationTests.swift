//
//  GenerationConfigRestorationTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

private actor ControlledImageLoader {
    private var startedPaths: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var loadContinuations: [String: CheckedContinuation<CGImage?, Never>] = [:]

    func load(_ path: String) async -> CGImage? {
        startedPaths.insert(path)
        for waiter in startWaiters.removeValue(forKey: path) ?? [] {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            loadContinuations[path] = continuation
        }
    }

    func waitUntilStarted(_ path: String) async {
        guard !startedPaths.contains(path) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[path, default: []].append(continuation)
        }
    }

    func finish(_ path: String, with image: CGImage?) {
        loadContinuations.removeValue(forKey: path)?.resume(returning: image)
    }
}

/// Pins the shared gallery/queue operation that turns recorded generation state
/// back into a sidebar configuration.
@MainActor
@Suite(.serialized)
struct GenerationConfigRestorationTests {
    let temp: TempDirectory
    let tempDefaults: TempDefaults
    let configStore: ConfigStore
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        tempDefaults = TempDefaults()
        configStore = ConfigStore(store: tempDefaults.defaults)
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
        configStore.modelDir = modelDir.path(percentEncoded: false)
        configStore.controlNetDir = controlNetDir.path(percentEncoded: false)
    }

    private func makeController(
        gallery: ImageGallery = ImageGallery(),
        fullImageProvider: GalleryFullImageProvider = GalleryFullImageProvider()
    ) -> GenerationController {
        let secrets = InMemorySecretStore([OpenAIImageEngine.secretAccount: "sk-test"])
        return makeTestGenerationController(
            configStore: configStore,
            imageGallery: gallery,
            engineRegistry: EngineRegistry.openAIBeta(secrets: secrets),
            fullImageProvider: fullImageProvider,
            startsObserving: false
        )
    }

    private func selectModel(
        _ name: String,
        on controller: GenerationController
    ) throws {
        controller.currentModelId = try #require(controller.models.first { $0.name == name }?.id)
    }

    @Test("A path-backed gallery image follows the selected model's image role")
    func galleryReuseLoadsIntoSupportedRole() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let imageURL = temp.appending("reuse.png")
        try writePNG(caption: "", to: imageURL, image: makeCGImage(width: 13, height: 7))
        let galleryImage = SDImage(
            image: nil,
            aspectRatio: 13.0 / 7.0,
            path: imageURL.path(percentEncoded: false)
        )
        let controller = makeController()
        await controller.loadModels()

        try selectModel("core", on: controller)
        #expect(controller.galleryImageDestination == .startingImage)
        await controller.useGalleryImage(galleryImage)
        #expect(controller.startingImage?.name == "reuse.png")
        #expect(controller.startingImage?.image.width == 13)
        #expect(controller.startingImage?.image.height == 7)

        try selectModel("gpt-image-2", on: controller)
        // Nothing to scrub first: selecting a model that reads references does not
        // move the starting image into them, so the list is still empty here.
        #expect(controller.inputImages.isEmpty)
        #expect(controller.galleryImageDestination == .inputImage)
        await controller.useGalleryImage(galleryImage)
        // The starting image chosen for the Core ML model is untouched by reuse
        // landing in the other role; it is simply inactive for this model.
        #expect(controller.startingImage?.name == "reuse.png")
        #expect(controller.inputImages.map(\.name) == ["reuse.png"])
        #expect(controller.inputImages.first?.image.width == 13)
        #expect(controller.inputImages.first?.image.height == 7)
    }

    @Test("Gallery reuse is unavailable without a destination or a free reference slot")
    func galleryReuseAvailabilityFollowsConstraintsAndLimit() async throws {
        let controller = makeController()
        #expect(controller.galleryImageDestination == nil)

        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)
        for index in 0..<controller.maxInputImageCount {
            controller.addInputImage(
                image: makeCGImage(),
                filename: "reference-\(index).png"
            )
        }

        #expect(controller.inputImages.count == controller.maxInputImageCount)
        #expect(controller.galleryImageDestination == nil)
    }

    @Test("A model change supersedes an in-flight gallery reuse")
    func galleryReuseDoesNotCrossModelChanges() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let controller = makeController(fullImageProvider: provider)
        await controller.loadModels()
        try selectModel("core", on: controller)
        let source = SDImage(image: nil, aspectRatio: 1, path: "/tmp/old.png")

        let reuse = Task { await controller.useGalleryImage(source) }
        await loader.waitUntilStarted("/tmp/old.png")
        try selectModel("gpt-image-2", on: controller)
        await loader.finish("/tmp/old.png", with: makeCGImage())
        await reuse.value

        #expect(controller.startingImage == nil)
        #expect(controller.inputImages.isEmpty)
    }

    @Test("A newer gallery reuse supersedes an older path load")
    func newerGalleryReuseWins() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let controller = makeController(fullImageProvider: provider)
        await controller.loadModels()
        try selectModel("core", on: controller)
        let first = SDImage(image: nil, aspectRatio: 1, path: "/tmp/first.png")
        let second = SDImage(image: nil, aspectRatio: 1, path: "/tmp/second.png")

        let firstReuse = Task { await controller.useGalleryImage(first) }
        await loader.waitUntilStarted("/tmp/first.png")
        let secondReuse = Task { await controller.useGalleryImage(second) }
        await loader.waitUntilStarted("/tmp/second.png")
        await loader.finish("/tmp/second.png", with: makeCGImage(width: 12, height: 8))
        await secondReuse.value
        await loader.finish("/tmp/first.png", with: makeCGImage(width: 8, height: 12))
        await firstReuse.value

        #expect(controller.startingImage?.name == "second.png")
        #expect(controller.startingImage?.image.width == 12)
        #expect(controller.startingImage?.image.height == 8)
    }

    @Test("A newer sidebar image supersedes an in-flight gallery reuse")
    func galleryReuseDoesNotOverwriteNewerSidebarState() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let controller = makeController(fullImageProvider: provider)
        await controller.loadModels()
        try selectModel("core", on: controller)
        let galleryImage = SDImage(image: nil, aspectRatio: 1, path: "/tmp/gallery.png")

        let reuse = Task { await controller.useGalleryImage(galleryImage) }
        await loader.waitUntilStarted("/tmp/gallery.png")
        controller.setStartingImage(
            image: makeCGImage(width: 20, height: 10),
            filename: "newer.png"
        )
        await loader.finish("/tmp/gallery.png", with: makeCGImage())
        await reuse.value

        #expect(controller.startingImage?.name == "newer.png")
        #expect(controller.startingImage?.image.width == 20)
        #expect(controller.startingImage?.image.height == 10)
    }

    /// A gallery holding one path-backed reference per name, and one OpenAI image
    /// per name whose metadata records that reference and a matching prompt.
    private func makeRestoreGallery(_ names: [String]) -> (ImageGallery, [String: SDImage]) {
        let gallery = ImageGallery()
        var entries: [(image: SDImage, metadataFields: Set<MetadataField>)] = []
        var sources: [String: SDImage] = [:]
        for name in names {
            let reference = SDImage(image: nil, aspectRatio: 1, path: "/tmp/\(name).png")
            var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
            source.model = "gpt-image-2"
            source.engine = EngineID.openAI.rawValue
            source.modelKey = "gpt-image-2"
            source.prompt = "prompt \(name)"
            source.inputImages = ["\(name).png"]
            entries.append((image: reference, metadataFields: []))
            entries.append(
                (
                    image: source,
                    metadataFields: [.model, .engine, .modelKey, .prompt, .inputImages]
                )
            )
            sources[name] = source
        }
        gallery.replaceAll(entries)
        return (gallery, sources)
    }

    @Test("A newer Copy Options owns the sidebar when an older one finishes last")
    func newerRestoreWinsOverOlderLoad() async throws {
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let (gallery, sources) = makeRestoreGallery(["a", "b"])
        let controller = makeController(gallery: gallery, fullImageProvider: provider)
        await controller.loadModels()

        let older = Task { await controller.copyToPrompt(try #require(sources["a"])) }
        await loader.waitUntilStarted("/tmp/a.png")
        let newer = Task { await controller.copyToPrompt(try #require(sources["b"])) }
        await loader.waitUntilStarted("/tmp/b.png")
        await loader.finish("/tmp/b.png", with: makeCGImage(width: 12, height: 8))
        try await newer.value
        await loader.finish("/tmp/a.png", with: makeCGImage(width: 8, height: 12))
        try await older.value

        #expect(configStore.prompt == "prompt b")
        #expect(controller.inputImages.map(\.name) == ["b.png"])
        #expect(controller.inputImages.first?.image.width == 12)
    }

    @Test("Edits made while Copy Options loads are not overwritten")
    func restoreDoesNotOverwriteNewerEdits() async throws {
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let (gallery, sources) = makeRestoreGallery(["a"])
        let controller = makeController(gallery: gallery, fullImageProvider: provider)
        await controller.loadModels()

        let restore = Task { await controller.copyToPrompt(try #require(sources["a"])) }
        await loader.waitUntilStarted("/tmp/a.png")
        configStore.prompt = "typed while loading"
        controller.addInputImage(image: makeCGImage(width: 20, height: 10), filename: "newer.png")
        await loader.finish("/tmp/a.png", with: makeCGImage())
        try await restore.value

        #expect(configStore.prompt == "typed while loading")
        #expect(controller.inputImages.map(\.name) == ["newer.png"])
    }

    @Test("A model change during Copy Options discards its late images")
    func restoreDoesNotCrossModelChanges() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let (gallery, sources) = makeRestoreGallery(["a"])
        let controller = makeController(gallery: gallery, fullImageProvider: provider)
        await controller.loadModels()

        let restore = Task { await controller.copyToPrompt(try #require(sources["a"])) }
        await loader.waitUntilStarted("/tmp/a.png")
        try selectModel("core", on: controller)
        await loader.finish("/tmp/a.png", with: makeCGImage())
        try await restore.value

        #expect(controller.currentModelId == ModelID(engine: .coreMLStableDiffusion, key: "core"))
        #expect(controller.inputImages.isEmpty)
    }

    @Test("A gallery reuse supersedes an in-flight Copy Options")
    func galleryReuseSupersedesRestore() async throws {
        let loader = ControlledImageLoader()
        let provider = GalleryFullImageProvider { path in
            await loader.load(path)
        }
        let (gallery, sources) = makeRestoreGallery(["a"])
        let controller = makeController(gallery: gallery, fullImageProvider: provider)
        await controller.loadModels()
        let reused = SDImage(image: nil, aspectRatio: 1, path: "/tmp/reused.png")

        let restore = Task { await controller.copyToPrompt(try #require(sources["a"])) }
        await loader.waitUntilStarted("/tmp/a.png")
        let reuse = Task { await controller.useGalleryImage(reused) }
        await loader.waitUntilStarted("/tmp/reused.png")
        await loader.finish("/tmp/reused.png", with: makeCGImage())
        await reuse.value
        await loader.finish("/tmp/a.png", with: makeCGImage())
        try await restore.value

        #expect(controller.inputImages.map(\.name) == ["reused.png"])
    }

    @Test("A queued unnamed starting image keeps its role and ControlNet")
    func queuedCoreMLRestoreKeepsExplicitImageRoles() async throws {
        let modelURL = modelDir.appending(path: "core-portrait")
        try makeSDModelFixture(
            at: modelURL,
            inputSize: CGSize(width: 512, height: 768),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(
            at: controlNetDir.appending(path: "canny.mlmodelc"),
            size: CGSize(width: 512, height: 768)
        )

        let controller = makeController()
        await controller.loadModels()
        try selectModel("core-portrait", on: controller)
        controller.setStartingImage(image: makeCGImage(width: 12, height: 8))
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(
            image: makeCGImage(width: 8, height: 12),
            filename: "guide.png"
        )
        configStore.strength = 0.35
        controller.numberOfImages = 3
        let source = try #require(controller.buildGenerationRequest())

        #expect(source.startingImageData != nil)
        #expect(source.startingImageName == nil)
        #expect(source.inputImageData.isEmpty)

        try selectModel("gpt-image-2", on: controller)
        controller.addInputImage(image: makeCGImage(), filename: "stale.png")
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == source.modelID)
        #expect(controller.startingImage != nil)
        #expect(controller.startingImage?.name == nil)
        #expect(controller.inputImages.isEmpty)
        #expect(controller.currentControlNets.first?.name == "canny")
        #expect(controller.currentControlNets.first?.imageFilename == "guide.png")
        #expect(configStore.width == 512)
        #expect(configStore.height == 768)
        #expect(configStore.strength == Double(try #require(source.strength)))
        #expect(controller.numberOfImages == 3)

        let restored = try #require(controller.buildGenerationRequest())
        #expect(restored.modelID == source.modelID)
        #expect(restored.startingImageData != nil)
        #expect(restored.inputImageData.isEmpty)
        #expect(restored.controlNetNames == source.controlNetNames)
        #expect(restored.controlNetImageNames == source.controlNetImageNames)
    }

    @Test("Queued Iris references keep exact values and positional names")
    func queuedIrisRestoreKeepsExactRequest() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein"))

        let controller = makeController()
        await controller.loadModels()
        try selectModel("klein", on: controller)
        configStore.width = 640
        configStore.height = 384
        controller.numberOfImages = 2
        controller.seed = 4242
        controller.addInputImage(image: makeCGImage(width: 12, height: 8))
        controller.addInputImage(
            image: makeCGImage(width: 8, height: 12),
            filename: "second.png"
        )
        let source = try #require(controller.buildGenerationRequest())

        #expect(source.inputImageNames == [nil, "second.png"])

        try selectModel("core", on: controller)
        controller.setStartingImage(image: makeCGImage(), filename: "stale.png")
        configStore.steps = 19
        configStore.scheduler = .pndmScheduler
        configStore.guidanceScale = 11
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == source.modelID)
        #expect(controller.startingImage == nil)
        #expect(controller.inputImages.map(\.name) == [nil, "second.png"])
        #expect(configStore.width == Int(source.size.width))
        #expect(configStore.height == Int(source.size.height))
        // Klein pins both, so the sidebar keeps what the user had. Copying them in
        // could not change the reproduction — the model pins them either way — and
        // would only overwrite the values waiting for the Core ML model.
        #expect(configStore.steps == 19)
        #expect(configStore.scheduler == .pndmScheduler)
        #expect(configStore.guidanceScale == 11)
        #expect(controller.seed == source.seed)
        #expect(controller.numberOfImages == Double(source.numberOfImages))

        let restored = try #require(controller.buildGenerationRequest())
        #expect(restored.modelID == source.modelID)
        #expect(restored.size == source.size)
        #expect(restored.stepCount == source.stepCount)
        #expect(restored.scheduler == source.scheduler)
        #expect(restored.inputImageNames == source.inputImageNames)
        #expect(restored.inputImageData.count == source.inputImageData.count)
    }

    @Test("A gallery restore loads path-backed OpenAI references")
    func galleryRestoreLoadsReferencesAndIntersectsConstraints() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let referenceURL = temp.appending("reference.png")
        try writePNG(caption: "", to: referenceURL, image: makeCGImage(width: 13, height: 7))

        let gallery = ImageGallery()
        let reference = SDImage(image: nil, aspectRatio: 13.0 / 7.0, path: referenceURL.path)
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "gpt-image-2"
        source.engine = EngineID.openAI.rawValue
        source.modelKey = "gpt-image-2"
        source.prompt = "restored prompt"
        source.negativePrompt = "not supported"
        source.steps = 99
        source.scheduler = .pndmScheduler
        source.quality = ImageQuality.high.rawValue
        source.inputImages = ["RÉFERENCE.PNG"]
        let fields: Set<MetadataField> = [
            .model, .engine, .modelKey, .prompt, .negativePrompt, .steps, .scheduler,
            .quality, .inputImages,
        ]
        gallery.replaceAll([
            (image: reference, metadataFields: []),
            (image: source, metadataFields: fields),
        ])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("core", on: controller)
        configStore.negativePrompt = "keep me"
        configStore.steps = 17
        configStore.scheduler = .discreteFlowScheduler
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == ModelID(engine: .openAI, key: "gpt-image-2"))
        #expect(configStore.prompt == "restored prompt")
        #expect(configStore.negativePrompt == "keep me")
        #expect(configStore.steps == 17)
        #expect(configStore.scheduler == .discreteFlowScheduler)
        #expect(configStore.quality == .high)
        #expect(controller.inputImages.count == 1)
        #expect(controller.inputImages.first?.name == "RÉFERENCE.PNG")
        #expect(controller.inputImages.first?.image.width == 13)
        #expect(controller.inputImages.first?.image.height == 7)
    }

    @Test("A missing exact model retains the current model and its constraints")
    func missingExactModelUsesCurrentConstraints() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let gallery = ImageGallery()
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "core"
        source.engine = EngineID.coreMLStableDiffusion.rawValue
        source.modelKey = "missing"
        source.prompt = "safe to copy"
        source.steps = 99
        let fields: Set<MetadataField> = [.model, .engine, .modelKey, .prompt, .steps]
        gallery.replaceAll([(image: source, metadataFields: fields)])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)
        configStore.steps = 21
        controller.addInputImage(image: makeCGImage(), filename: "stale.png")
        let selected = controller.currentModelId

        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == selected)
        #expect(configStore.prompt == "safe to copy")
        #expect(configStore.steps == 21)
        #expect(controller.inputImages.isEmpty)
    }

    @Test("Copy Options restores a recorded strength and leaves an absent one alone")
    func strengthRestore() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let gallery = ImageGallery()
        var withStrength = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        withStrength.strength = 0.35
        var withoutStrength = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        withoutStrength.strength = 0.9
        gallery.replaceAll([
            (image: withStrength, metadataFields: [.strength]),
            (image: withoutStrength, metadataFields: []),
        ])
        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("core", on: controller)
        configStore.strength = 0.6

        await controller.copyToPrompt(withoutStrength)
        #expect(configStore.strength == 0.6)

        await controller.copyToPrompt(withStrength)
        #expect(configStore.strength == 0.35)
    }

    /// The gallery image of the file at `url`, read the way the gallery reads it.
    private func galleryImage(readFrom url: URL, in gallery: ImageGallery) throws -> SDImage {
        let record = try #require(createImageRecordFromURL(url))
        let sdi = try #require(createSDImage(from: record))
        gallery.replaceAll([(image: sdi, metadataFields: record.metadataFields)])
        return sdi
    }

    @Test("Copy Options restores the settings a generated file recorded")
    func restoreFromGeneratedFile() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let metadata = GenerationMetadata(
            prompt: "a cat\nwearing a hat", negativePrompt: "blurry", width: 512, height: 512,
            model: "core", engine: EngineID.coreMLStableDiffusion.rawValue, modelKey: "core",
            architecture: SDModel.ModelType.sd15.displayName, quality: nil, startingImage: nil,
            strength: nil, controlNet: nil, controlNetImage: nil, inputImages: nil,
            scheduler: .pndmScheduler, mlComputeUnit: .cpuAndGPU, seed: UInt32.max, steps: 23,
            guidanceScale: 6.5, generatedDate: Date(), metadataFields: [])
        let url = temp.appending("generated.png")
        try #require(await metadata.pngData(for: makeCGImage())).write(to: url)
        let gallery = ImageGallery()
        let sdi = try galleryImage(readFrom: url, in: gallery)
        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)

        await controller.copyToPrompt(sdi)

        #expect(controller.currentModelId == ModelID(engine: .coreMLStableDiffusion, key: "core"))
        #expect(configStore.prompt == "a cat\nwearing a hat")
        #expect(configStore.negativePrompt == "blurry")
        #expect(configStore.steps == 23)
        #expect(configStore.guidanceScale == 6.5)
        #expect(configStore.scheduler == .pndmScheduler)
        #expect(controller.seed == UInt32.max)
        #expect(configStore.mlComputeUnitPreference == ComputeUnitPreference(exact: .cpuAndGPU))
    }

    @Test("Copy Options from another application's image restores only what Mochi can use")
    func restoreFromForeignFile() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let url = temp.appending("foreign.png")
        try PNGTestChunks.write(
            textChunks: [
                (
                    "parameters",
                    "a dog\nNegative prompt: cat\nSteps: 12, Sampler: Euler a, CFG scale: 5, Seed: 8589934592, Size: 8x8, Model: dreamshaper"
                )
            ], to: url)
        let gallery = ImageGallery()
        let sdi = try galleryImage(readFrom: url, in: gallery)
        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("core", on: controller)
        configStore.scheduler = .dpmSolverMultistepScheduler
        controller.seed = 7

        await controller.copyToPrompt(sdi)

        #expect(configStore.prompt == "a dog")
        #expect(configStore.negativePrompt == "cat")
        #expect(configStore.steps == 12)
        #expect(configStore.guidanceScale == 5)
        // Neither a sampler Mochi does not offer nor a seed above UInt32 is restored.
        #expect(configStore.scheduler == .dpmSolverMultistepScheduler)
        #expect(controller.seed == 7)
    }

    @Test("Legacy gallery metadata falls back to an unambiguous display name")
    func legacyModelNameFallbackStillWorks() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "legacy-core"))
        let gallery = ImageGallery()
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "legacy-core"
        gallery.replaceAll([(image: source, metadataFields: [.model])])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)

        await controller.copyToPrompt(source)

        #expect(
            controller.currentModelId
                == ModelID(engine: .coreMLStableDiffusion, key: "legacy-core")
        )
    }
}
