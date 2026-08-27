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
/// This replaces the sniffing chain in `ModelRepository.load`, where the first
/// matching kind won and a single thrown error emptied the whole model list. The
/// test that pinned that precedence — `kleinTakesPrecedenceOverCoreML` — is gone
/// with it, since exclusivity was the behaviour being removed.
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

    // MARK: - Each engine sees only its own models

    @Test("Each engine discovers only the models it recognises")
    func enginesDiscoverOnlyTheirOwn() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        try writeFile("{}", to: modelDir.appending(components: "not-a-model", "readme.txt"))

        let coreML = try await CoreMLStableDiffusionEngine().discoverModels(settings)
        let iris = try await IrisEngine().discoverModels(settings)

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

        let coreML = try await CoreMLStableDiffusionEngine().discoverModels(settings)
        let iris = try await IrisEngine().discoverModels(settings)

        #expect(coreML.map(\.id) == [ModelID(engine: .coreMLStableDiffusion, key: "ambiguous")])
        #expect(iris.map(\.id) == [ModelID(engine: .iris, key: "ambiguous")])
        // Same directory, same name, two models — separable only because the id
        // carries the engine.
        #expect(coreML[0].name == iris[0].name)
        #expect(coreML[0].id != iris[0].id)
    }

    @Test("An empty models directory yields no models and no error")
    func emptyDirectoryIsNotAnError() async throws {
        #expect(try await CoreMLStableDiffusionEngine().discoverModels(settings).isEmpty)
        #expect(try await IrisEngine().discoverModels(settings).isEmpty)
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

    @Test("A ControlNet-capable model gets a controlnet symlink into the shared folder")
    func createsControlNetSymlink() async throws {
        let modelURL = modelDir.appending(path: "controlled-model")
        try makeSDModelFixture(at: modelURL, unetName: "ControlledUnet.mlmodelc")

        _ = try await CoreMLStableDiffusionEngine().discoverModels(settings)

        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: modelURL.appending(path: "controlnet").path(percentEncoded: false)
        )
        #expect(destination == controlNetDir.path(percentEncoded: false))
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

        let models = try await CoreMLStableDiffusionEngine().discoverModels(settings)

        #expect(try #require(models.first).controlNet == ["canny"])
    }

    @Test("A model without a ControlledUnet is offered no ControlNets")
    func plainModelGetsNoControlNets() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "plain-model"))
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))

        let models = try await CoreMLStableDiffusionEngine().discoverModels(settings)

        #expect(try #require(models.first).controlNet.isEmpty)
    }
}

/// The engine, its models and its payload are one checked triple. §5.4 of
/// `Multi-Engine-Design.md` asks for a payload that "can only be executed by its
/// originating engine"; these are that.
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

    private var draft: GenerationDraft {
        GenerationDraft(
            prompt: "a cat",
            negativePrompt: "",
            configuredSize: CGSize(width: 512, height: 512),
            startingImage: nil,
            startingImageName: nil,
            controlNets: [],
            strength: 0.5,
            stepCount: 12,
            guidanceScale: 11,
            scheduler: .dpmSolverMultistepScheduler,
            seed: 1,
            numberOfImages: 1,
            computeUnitPreference: .auto,
            reduceMemory: false,
            safetyChecker: false,
            showGenerationPreview: false,
            imageDir: "",
            imageType: "png"
        )
    }

    @Test("An engine accepts only the payload type it produces")
    func engineAcceptsOnlyItsOwnPayload() {
        let coreML = AnyGenerationEngine(CoreMLStableDiffusionEngine())
        let iris = AnyGenerationEngine(IrisEngine())
        let irisPayload = IrisGenerationPayload(modelDirectory: "/models/klein")

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
            try await CoreMLStableDiffusionEngine().discoverModels(settings).first)
        let kleinModel = try #require(try await IrisEngine().discoverModels(settings).first)

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
            try await CoreMLStableDiffusionEngine().discoverModels(settings).first)
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
        func discoverModels(_ settings: EngineSettings) async throws -> [SDModel] {
            throw Failure()
        }
        func plan(draft: GenerationDraft, model: SDModel) throws
            -> GenerationPlan<CoreMLGenerationPayload>
        {
            throw Failure()
        }
    }

    @Test("Discovery covers every registered engine")
    func discoversAllEngines() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        let registry = EngineRegistry()

        let discoveries = await registry.discoverAll(settings: settings)

        #expect(Set(discoveries.map(\.engine)) == [.iris, .coreMLStableDiffusion])
        #expect(discoveries.allModels.count == 2)
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
        #expect(discoveries.failures.count == 2)
    }

    @Test("Availability is reported per engine")
    func availabilityIsPerEngine() async throws {
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(FailingEngine()),
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
        ])

        let availability = await registry.availability(settings)

        #expect(availability[EngineID(rawValue: "failing")] == .needsConfiguration("always"))
        #expect(availability[.coreMLStableDiffusion] == .ready)
    }

    // MARK: - Ordering

    @Test("The combined list is sorted by name, case- and diacritic-insensitively")
    func combinedListIsSortedByName() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "B-coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "a-klein-model"))

        let models = await EngineRegistry().discoverAll(settings: settings).allModels

        // Preserved from the pre-engine loader: one flat list ordered by name,
        // regardless of which engine found what. Phase 5 groups by engine.
        #expect(models.map(\.name) == ["a-klein-model", "B-coreml-model"])
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
        #expect(models.count == 2)
    }
}
