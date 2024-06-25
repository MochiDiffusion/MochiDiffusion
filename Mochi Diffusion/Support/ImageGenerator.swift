//
//  ImageGenerator.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Combine
import CoreML
import OSLog
@preconcurrency import StableDiffusion
import UniformTypeIdentifiers

struct GenerationConfig: Sendable, Identifiable {
    let id = UUID()
    var pipelineConfig: StableDiffusionPipeline.Configuration
    var isXL: Bool
    var isSD3: Bool
    var autosaveImages: Bool
    var imageDir: String
    var imageType: String
    var numberOfImages: Int
    let model: SDModel
    var mlComputeUnit: MLComputeUnits
    var scheduler: Scheduler
    var upscaleGeneratedImages: Bool
    var controlNets: [String]
}

@Observable public final class ImageGenerator {

    static let shared = ImageGenerator()

    enum GeneratorError: Error {
        case imageDirectoryNoAccess
        case modelDirectoryNoAccess
        case modelSubDirectoriesNoAccess
        case noModelsFound
        case pipelineNotAvailable
        case requestedModelNotFound
    }

    enum State: Sendable {
        case ready(String?)
        case error(String)
        case loading
        case running(StableDiffusionProgress?)
    }

    private(set) var state = State.ready(nil)

    struct QueueProgress: Sendable {
        var index = 0
        var total = 0
    }

    private(set) var queueProgress = QueueProgress(index: 0, total: 0)

    private var pipeline: (any StableDiffusionPipelineProtocol)?

    private var generationStopped = false

    private(set) var lastStepGenerationElapsedTime: Double?

    private var generationStartTime: DispatchTime?

    private var currentPipelineHash: Int?

    func loadImages(imageDir: String) async throws -> ([SDImage], URL) {
        var finalImageDirURL: URL
        let fm = FileManager.default
        /// check if image autosave directory exists
        if imageDir.isEmpty {
            /// use default autosave directory
            finalImageDirURL = fm.homeDirectoryForCurrentUser
            finalImageDirURL.append(path: "MochiDiffusion/images", directoryHint: .isDirectory)
        } else {
            /// generate url from autosave directory
            finalImageDirURL = URL(fileURLWithPath: imageDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalImageDirURL.path(percentEncoded: false)) {
            print(
                "Creating image autosave directory at: \"\(finalImageDirURL.path(percentEncoded: false))\""
            )
            try? fm.createDirectory(at: finalImageDirURL, withIntermediateDirectories: true)
        }
        let items = try fm.contentsOfDirectory(
            at: finalImageDirURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        let imageURLs =
            items
            .filter { $0.isFileURL }
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension) }
        var sdis: [SDImage] = []
        for url in imageURLs {
            guard let sdi = createSDImageFromURL(url) else { continue }
            sdis.append(sdi)
        }
        sdis.sort { $0.generatedDate < $1.generatedDate }
        return (sdis, finalImageDirURL)
    }

    private func controlNets(in controlNetDirectoryURL: URL) -> [SDControlNet] {
        let controlNetDirectoryPath = controlNetDirectoryURL.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: controlNetDirectoryPath),
            let contentsOfControlNet = try? FileManager.default.contentsOfDirectory(
                atPath: controlNetDirectoryPath)
        else {
            return []
        }

        return contentsOfControlNet.compactMap {
            SDControlNet(url: controlNetDirectoryURL.appending(path: $0))
        }
    }

    func getModels(modelDirectoryURL: URL, controlNetDirectoryURL: URL) async throws -> [SDModel] {
        var models: [SDModel] = []
        let fm = FileManager.default

        do {
            let controlNet = controlNets(in: controlNetDirectoryURL)
            let subDirs = try modelDirectoryURL.subDirectories()

            models =
                subDirs
                .sorted {
                    $0.lastPathComponent.compare(
                        $1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedAscending
                }
                .compactMap { url in
                    let controlledUnetMetadataPath = url.appending(
                        components: "ControlledUnet.mlmodelc", "metadata.json"
                    ).path(percentEncoded: false)
                    let hasControlNet = fm.fileExists(atPath: controlledUnetMetadataPath)

                    if hasControlNet {
                        let controlNetSymLinkPath = url.appending(component: "controlnet").path(
                            percentEncoded: false)

                        if !fm.fileExists(atPath: controlNetSymLinkPath) {
                            try? fm.createSymbolicLink(
                                atPath: controlNetSymLinkPath,
                                withDestinationPath: controlNetDirectoryURL.path(
                                    percentEncoded: false))
                        }
                    }

                    return SDModel(
                        url: url, name: url.lastPathComponent,
                        controlNet: hasControlNet ? controlNet : [])
                }
        } catch {
            await updateState(.error("Could not get model subdirectories."))
            throw GeneratorError.modelSubDirectoriesNoAccess
        }
        if models.isEmpty {
            await updateState(
                .error("No models found under: \(modelDirectoryURL.path(percentEncoded: false))"))
            throw GeneratorError.noModelsFound
        }
        return models
    }

    func loadPipeline(
        model: SDModel, controlNet: [String] = [], computeUnit: MLComputeUnits, reduceMemory: Bool
    ) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            await updateState(.error("Couldn't load \(model.name) because it doesn't exist."))
            throw GeneratorError.requestedModelNotFound
        }

        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(controlNet)
        hasher.combine(computeUnit)
        hasher.combine(reduceMemory)
        let hash = hasher.finalize()
        guard hash != self.currentPipelineHash else { return }

        await updateState(.loading)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnit

        if model.isXL {
            self.pipeline = try StableDiffusionXLPipeline(
                resourcesAt: model.url,
                configuration: config,
                reduceMemory: reduceMemory
            )
        } else if model.isSD3 {
            self.pipeline = try StableDiffusion3Pipeline(
                resourcesAt: model.url,
                configuration: config,
                reduceMemory: reduceMemory
            )
        } else {
            self.pipeline = try StableDiffusionPipeline(
                resourcesAt: model.url,
                controlNet: controlNet,
                configuration: config,
                disableSafety: true,
                reduceMemory: reduceMemory
            )
        }

        self.currentPipelineHash = hash
        await updateState(.ready(nil))
    }

    func generate(_ inputConfig: GenerationConfig) async throws {
        guard let pipeline = pipeline else {
            await updateState(.error("Pipeline is not loaded."))
            throw GeneratorError.pipelineNotAvailable
        }
        await updateState(.loading)
        generationStopped = false
        var config = inputConfig
        config.pipelineConfig.seed =
            config.pipelineConfig.seed == 0
            ? UInt32.random(in: 0..<UInt32.max) : config.pipelineConfig.seed

        if config.isXL {
            config.pipelineConfig.encoderScaleFactor = 0.13025
            config.pipelineConfig.decoderScaleFactor = 0.13025
            config.pipelineConfig.schedulerTimestepSpacing = .karras
        }

        if config.isSD3 {
            config.pipelineConfig.encoderScaleFactor = 1.5305
            config.pipelineConfig.decoderScaleFactor = 1.5305
            config.pipelineConfig.decoderShiftFactor = 0.0609
            config.pipelineConfig.schedulerTimestepShift = 3.0
        }

        var sdi = SDImage()
        sdi.prompt = config.pipelineConfig.prompt
        sdi.negativePrompt = config.pipelineConfig.negativePrompt
        sdi.model = config.model.name
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = config.pipelineConfig.stepCount
        sdi.guidanceScale = Double(config.pipelineConfig.guidanceScale)

        for index in 0..<config.numberOfImages {
            await updateQueueProgress(
                QueueProgress(index: index, total: inputConfig.numberOfImages))
            generationStartTime = DispatchTime.now()
            let images = try pipeline.generateImages(configuration: config.pipelineConfig) {
                [config] progress in

                Task { @MainActor in
                    state = .running(progress)
                    let endTime = DispatchTime.now()
                    lastStepGenerationElapsedTime = Double(
                        endTime.uptimeNanoseconds - (generationStartTime?.uptimeNanoseconds ?? 0))
                    generationStartTime = endTime
                }

                Task {
                    if config.pipelineConfig.useDenoisedIntermediates,
                        let currentImage = progress.currentImages.last
                    {
                        ImageStore.shared.setCurrentGenerating(image: currentImage)
                    } else {
                        ImageStore.shared.setCurrentGenerating(image: nil)
                    }
                }

                return !generationStopped
            }
            if generationStopped {
                break
            }
            for image in images {
                guard let image = image else { continue }
                if config.upscaleGeneratedImages {
                    guard let upscaledImg = await Upscaler.shared.upscale(cgImage: image) else {
                        continue
                    }
                    sdi.image = upscaledImg
                    sdi.aspectRatio = CGFloat(
                        Double(upscaledImg.width) / Double(upscaledImg.height))
                    sdi.upscaler = "RealESRGAN"
                } else {
                    sdi.image = image
                    sdi.aspectRatio = CGFloat(Double(image.width) / Double(image.height))
                }
                sdi.id = UUID()
                sdi.seed = config.pipelineConfig.seed
                sdi.generatedDate = Date.now
                sdi.path = ""

                if config.autosaveImages && !config.imageDir.isEmpty {
                    var pathURL = URL(fileURLWithPath: config.imageDir, isDirectory: true)
                    let count = ImageStore.shared.images.endIndex + 1
                    pathURL.append(path: sdi.filenameWithoutExtension(count: count))

                    let type = UTType.fromString(config.imageType)
                    guard let path = await sdi.save(pathURL, type: type) else { continue }
                    sdi.path = path.path(percentEncoded: false)
                }
                ImageStore.shared.add(sdi)
            }
            config.pipelineConfig.seed += 1
        }
        await updateState(.ready(nil))
    }

    func stopGenerate() async {
        generationStopped = true
    }

    func updateState(_ state: State) async {
        Task { @MainActor in
            self.state = state
        }
    }

    private func updateQueueProgress(_ queueProgress: QueueProgress) async {
        Task { @MainActor in
            self.queueProgress = queueProgress
        }
    }
}

extension URL {
    func subDirectories() throws -> [URL] {
        guard hasDirectoryPath else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
    }
}
