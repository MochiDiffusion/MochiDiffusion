//
//  EngineDiscoveryTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Engines discover independently: each applies only its own recognition rules to
/// its own configured source, and nothing arbitrates between them.
///
/// Two consequences worth pinning: a directory both engines recognise is offered
/// twice under distinct ids rather than claimed by one, and one engine failing
/// leaves every other engine's models intact.
struct EngineDiscoveryTests {
    let temp: TempDirectory
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
    }

    private var settings: EngineSettings {
        EngineSettings(modelDirectory: modelDir, controlNetDirectory: controlNetDir)
    }

    private var context: ModelDiscoveryContext {
        ModelDiscoveryContext(settings: settings)
    }

    // MARK: - Each engine sees only its own models

    @Test("Each engine discovers only the models it recognises")
    func enginesDiscoverOnlyTheirOwn() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        try writeFile("{}", to: modelDir.appending(components: "not-a-model", "readme.txt"))

        let coreML = try await CoreMLStableDiffusionEngine().discoverModels(context)
        let iris = try await IrisEngine().discoverModels(context)

        #expect(coreML.map(\.name) == ["coreml-model"])
        #expect(iris.map(\.name) == ["klein-model"])
    }

    /// The point of engine-qualified identity. The old loader picked one kind and
    /// discarded the other; both are now offered, and the user chooses.
    @Test("A directory both engines recognise is offered by both, under distinct ids")
    func sharedDirectoryIsOfferedByBothEngines() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)

        let coreML = try await CoreMLStableDiffusionEngine().discoverModels(context)
        let iris = try await IrisEngine().discoverModels(context)

        #expect(coreML.map(\.id) == [ModelID(engine: .coreMLStableDiffusion, key: "ambiguous")])
        #expect(iris.map(\.id) == [ModelID(engine: .iris, key: "ambiguous")])
        // Same directory, same name, two models — separable only because the id
        // carries the engine.
        #expect(coreML[0].name == iris[0].name)
        #expect(coreML[0].id != iris[0].id)
    }

    @Test("An empty models directory yields no models and no error")
    func emptyDirectoryIsNotAnError() async throws {
        #expect(try await CoreMLStableDiffusionEngine().discoverModels(context).isEmpty)
        #expect(try await IrisEngine().discoverModels(context).isEmpty)
    }

    @Test("A missing models directory reports the engine as unreachable")
    func missingDirectoryIsUnreachable() async throws {
        let missing = EngineSettings(
            modelDirectory: temp.appending("nope"),
            controlNetDirectory: controlNetDir
        )

        let coreML = await CoreMLStableDiffusionEngine().availability(missing)
        let iris = await IrisEngine().availability(missing)

        #expect(coreML != .ready)
        #expect(iris != .ready)
        if case .unreachable = coreML {
        } else {
            Issue.record("expected .unreachable, got \(coreML)")
        }
    }

    @Test("A present models directory reports the engine as ready")
    func presentDirectoryIsReady() async throws {
        #expect(await CoreMLStableDiffusionEngine().availability(settings) == .ready)
        #expect(await IrisEngine().availability(settings) == .ready)
    }

    // MARK: - Core ML specifics stay in the Core ML engine

    /// Discovery used to drop a `controlnet` symlink into every capable model
    /// directory, which meant writing to the user's models folder from a read
    /// path on every folder-change event. The link is still needed — the Apple
    /// pipeline resolves bundles relative to the model — but `CoreMLEngineRuntime`
    /// now creates it when it is about to load a ControlNet pipeline.
    @Test("Discovery does not write into the models folder")
    func discoveryDoesNotWrite() async throws {
        let modelURL = modelDir.appending(path: "controlled-model")
        try makeSDModelFixture(at: modelURL, unetName: "ControlledUnet.mlmodelc")

        _ = try await CoreMLStableDiffusionEngine().discoverModels(context)

        #expect(
            !FileManager.default.fileExists(
                atPath: modelURL.appending(path: "controlnet").path(percentEncoded: false)
            )
        )
    }

    @Test("Matching ControlNets are offered to a ControlNet-capable model")
    func controlNetsAreOffered() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "controlled-model"),
            inputSize: CGSize(width: 512, height: 512),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        try makeControlNetFixture(
            at: controlNetDir.appending(path: "wrong-size.mlmodelc"),
            size: CGSize(width: 768, height: 768)
        )

        let models = try await CoreMLStableDiffusionEngine().discoverModels(context)

        #expect(try #require(models.first).controlNet == ["canny"])
    }

    @Test("A model without a ControlledUnet is offered no ControlNets")
    func plainModelGetsNoControlNets() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "plain-model"))
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))

        let models = try await CoreMLStableDiffusionEngine().discoverModels(context)

        #expect(try #require(models.first).controlNet.isEmpty)
    }
}

/// An engine, its model type and its payload type are one checked triple, so a
/// payload can only be executed by the engine that produced it.
struct EnginePayloadOwnershipTests {
    let temp: TempDirectory
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
    }

    private var settings: EngineSettings {
        EngineSettings(modelDirectory: modelDir, controlNetDirectory: controlNetDir)
    }

    private var context: ModelDiscoveryContext {
        ModelDiscoveryContext(settings: settings)
    }

    private var draft: GenerationDraft {
        GenerationDraft(
            prompt: "a cat",
            negativePrompt: "",
            configuredSize: CGSize(width: 512, height: 512),
            inputImages: [],
            controlNets: [],
            strength: 0.5,
            stepCount: 12,
            guidanceScale: 11,
            scheduler: .dpmSolverMultistepScheduler,
            quality: .auto,
            seed: 1,
            numberOfImages: 1,
            computeUnitPreference: .auto,
            reduceMemory: false,
            safetyChecker: false,
            showGenerationPreview: false,
            imageDir: "",
            imageType: "png",
            controlNetDirectory: controlNetDir
        )
    }

    @Test("An engine accepts only the payload type it produces")
    func engineAcceptsOnlyItsOwnPayload() {
        let coreML = AnyGenerationEngine(CoreMLStableDiffusionEngine())
        let iris = AnyGenerationEngine(IrisEngine())
        let irisPayload = IrisGenerationPayload(
            modelDirectory: "/models/klein",
            stepCount: 4,
            scheduler: .discreteFlowScheduler
        )

        #expect(iris.accepts(payload: irisPayload))
        // The check that stops a request reaching a generator that cannot run it.
        #expect(!coreML.accepts(payload: irisPayload))
    }

    @Test("A payload produced by planning is accepted by its own engine only")
    func plannedPayloadBelongsToItsEngine() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        let coreML = AnyGenerationEngine(CoreMLStableDiffusionEngine())
        let iris = AnyGenerationEngine(IrisEngine())
        let sdModel = try #require(
            try await CoreMLStableDiffusionEngine().discoverModels(context).first)
        let kleinModel = try #require(try await IrisEngine().discoverModels(context).first)

        let coreMLPlan = try coreML.plan(draft: draft, model: sdModel)
        let irisPlan = try iris.plan(draft: draft, model: kleinModel)

        #expect(coreML.accepts(payload: coreMLPlan.payload))
        #expect(iris.accepts(payload: irisPlan.payload))
        #expect(!coreML.accepts(payload: irisPlan.payload))
        #expect(!iris.accepts(payload: coreMLPlan.payload))
    }

    @Test("An engine refuses to plan for another engine's model")
    func engineRefusesForeignModel() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let sdModel = try #require(
            try await CoreMLStableDiffusionEngine().discoverModels(context).first)
        let iris = AnyGenerationEngine(IrisEngine())

        #expect(throws: EngineError.modelDoesNotBelongToEngine(model: sdModel.id, engine: .iris)) {
            _ = try iris.plan(draft: draft, model: sdModel)
        }
    }
}

/// The registry aggregates without arbitrating, and keeps one engine's failure
/// from looking like everyone's.
struct EngineRegistryTests {
    let temp: TempDirectory
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
    }

    private var settings: EngineSettings {
        EngineSettings(modelDirectory: modelDir, controlNetDirectory: controlNetDir)
    }

    private var context: ModelDiscoveryContext {
        ModelDiscoveryContext(settings: settings)
    }

    /// An engine whose discovery always fails, to prove failure isolation without
    /// depending on how a real engine happens to fail.
    private struct FailingEngine: GenerationEngineDescriptor {
        typealias Model = SDModel
        typealias Payload = CoreMLGenerationPayload
        struct Failure: Error {}
        static let id = EngineID(rawValue: "failing")
        var displayName: String { "Failing" }
        func availability(_ settings: EngineSettings) async -> EngineAvailability {
            .needsConfiguration("always")
        }
        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [SDModel] {
            throw Failure()
        }
        func plan(draft: GenerationDraft, model: SDModel) throws
            -> GenerationPlan<CoreMLGenerationPayload>
        {
            throw Failure()
        }
        func makeRuntime() -> any GenerationEngineRuntime {
            NeverRunsRuntime()
        }
    }

    /// This engine never gets as far as running anything; discovery fails first.
    private struct NeverRunsRuntime: GenerationEngineRuntime {
        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            throw FailingEngine.Failure()
        }
    }

    /// Stands in for a hosted engine: it has models, and it never looks at the
    /// models folder. Its `url` is a placeholder because `EngineModel.url` is not
    /// optional yet — which is itself a Phase 6 prerequisite.
    private struct FolderIgnoringEngine: GenerationEngineDescriptor {
        struct Model: EngineModel {
            let id: ModelID
            let url: URL
            let name: String
            var constraints: OptionConstraints { .unconstrained }
            var metadataFields: Set<MetadataField> { [.prompt] }
            var tokenizerModelDir: URL? { nil }
        }
        struct Payload: Sendable {}
        struct NotRun: Error {}

        static let id = EngineID(rawValue: "folder-ignoring")
        var displayName: String { "Folder Ignoring" }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

        /// Never calls `context.localModelDirectories()`, so an unreadable models
        /// folder cannot fail it.
        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
            [
                Model(
                    id: ModelID(engine: Self.id, key: "hosted-model"),
                    url: URL(fileURLWithPath: "/dev/null"),
                    name: "hosted-model"
                )
            ]
        }

        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            throw NotRun()
        }

        func makeRuntime() -> any GenerationEngineRuntime { NeverRunsRuntime() }
    }

    // MARK: - Shared enumeration

    /// The mechanism behind sharing: a context enumerates when it is built, so
    /// handing one context to every engine in a pass costs one enumeration. If it
    /// re-read the folder per call, the directory added below would show up.
    @Test("A context enumerates once, not once per engine that asks")
    func contextEnumeratesOnce() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "first"))
        let context = self.context

        try makeKleinModelFixture(at: modelDir.appending(path: "second"))

        let names = try context.localModelDirectories().map(ModelID.localKey(for:))
        #expect(names == ["first"])
    }

    @Test("Every engine in one pass sees the same candidate directories")
    func onePassSharesOneEnumeration() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))

        let discoveries = await EngineRegistry().discoverAll(settings: settings)

        // Both engines saw both directories and each recognised its own, which is
        // only possible if the shared enumeration reached both.
        #expect(
            discoveries.allModels.map(\.name) == ["coreml-model", "gpt-image-2", "klein-model"])
        #expect(discoveries.failures.isEmpty)
    }

    /// Failure isolation one level lower than `failureIsIsolated`: there the
    /// engine itself failed, here the *shared* enumeration failed, and it must
    /// still only fail the engines that depended on it.
    @Test("An unreadable models folder spares an engine that never reads it")
    func unreadableFolderSparesEnginesThatIgnoreIt() async throws {
        // Built the way `ModelRepository.modelDirectoryURL` builds it: with a
        // directory path, so enumeration reaches the filesystem and throws.
        // A URL without the hint makes `subDirectories` return empty instead,
        // which is "no models" rather than "could not read".
        let missing = EngineSettings(
            modelDirectory: temp.url.appending(path: "nope", directoryHint: .isDirectory),
            controlNetDirectory: controlNetDir
        )
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
            AnyGenerationEngine(FolderIgnoringEngine()),
        ])

        let discoveries = await registry.discoverAll(settings: missing)

        #expect(discoveries.allModels.map(\.name) == ["hosted-model"])
        #expect(discoveries.failures.map(\.engine) == [.coreMLStableDiffusion])
    }

    @Test("Discovery covers every registered engine")
    func discoversAllEngines() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        let registry = EngineRegistry()

        let discoveries = await registry.discoverAll(settings: settings)

        #expect(
            Set(discoveries.map(\.engine)) == [.iris, .coreMLStableDiffusion, .openAI, .drawThings])
        // Two local models plus the hosted engine's one.
        #expect(discoveries.allModels.count == 3)
        #expect(discoveries.failures.isEmpty)
    }

    /// The behaviour the old loader could not express: it threw one error for the
    /// whole load, so any engine's problem emptied the list.
    @Test("One engine failing does not erase another engine's models")
    func failureIsIsolated() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(FailingEngine()),
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
        ])

        let discoveries = await registry.discoverAll(settings: settings)

        #expect(discoveries.allModels.map(\.name) == ["coreml-model"])
        #expect(discoveries.failures.map(\.engine) == [EngineID(rawValue: "failing")])
    }

    @Test("Discovery never throws, however many engines fail")
    func discoveryNeverThrows() async throws {
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(FailingEngine()),
            AnyGenerationEngine(FailingEngine()),
        ])

        let discoveries = await registry.discoverAll(settings: settings)

        #expect(discoveries.allModels.isEmpty)
        // Both local engines fail on an unreadable folder; the hosted engine
        // never touches it, which is why it is not counted here.
        #expect(discoveries.failures.count == 2)
    }

    @Test("Availability is reported per engine")
    func availabilityIsPerEngine() async throws {
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(FailingEngine()),
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
        ])

        let availability = await registry.refresh(settings: settings).availability

        // `FailingEngine` also fails discovery, and its own reason survives that: an
        // engine that has said why it cannot be used has given the actionable
        // answer, and its discovery failing follows from it.
        #expect(availability[EngineID(rawValue: "failing")] == .needsConfiguration("always"))
        #expect(availability[.coreMLStableDiffusion] == .ready)
    }

    // MARK: - Ordering

    @Test("The combined list is sorted by name, case- and diacritic-insensitively")
    func combinedListIsSortedByName() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "B-coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "a-klein-model"))

        let models = await EngineRegistry().discoverAll(settings: settings).allModels

        // One flat list ordered by name, regardless of which engine found what.
        // Case- and diacritic-insensitive, and the hosted model sorts among
        // the local ones like any other name.
        #expect(models.map(\.name) == ["a-klein-model", "B-coreml-model", "gpt-image-2"])
    }

    /// Independent discovery makes duplicate names reachable, so the order of that
    /// pair must not depend on which engine happened to answer first.
    @Test("Models sharing a name are ordered deterministically by engine")
    func duplicateNamesAreOrderedDeterministically() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)

        let forward = await EngineRegistry(engines: [
            AnyGenerationEngine(IrisEngine()), AnyGenerationEngine(CoreMLStableDiffusionEngine()),
        ]).discoverAll(settings: settings).allModels
        let reversed = await EngineRegistry(engines: [
            AnyGenerationEngine(CoreMLStableDiffusionEngine()), AnyGenerationEngine(IrisEngine()),
        ]).discoverAll(settings: settings).allModels

        #expect(forward.map(\.id) == reversed.map(\.id))
        #expect(forward.map(\.id.engine) == [.coreMLStableDiffusion, .iris])
    }

    @Test("Registration order does not decide which engine owns a shared directory")
    func registrationOrderIsNotOwnership() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)

        let models = await EngineRegistry().discoverAll(settings: settings).allModels

        // Both, not one. This is what `kleinTakesPrecedenceOverCoreML` used to
        // assert the opposite of.
        // Two local models plus the hosted engine's one.
        #expect(models.count == 3)
    }
}
