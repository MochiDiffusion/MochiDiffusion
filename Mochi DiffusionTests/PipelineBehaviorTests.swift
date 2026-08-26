//
//  PipelineBehaviorTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins how a pipeline resolves a user request into the values actually used.
///
/// `GenerationPipeline` is expected to be replaced by a per-provider constraint
/// model. When that happens these assertions must still hold: whatever the new
/// shape, a Klein generation still runs 4 steps on the flow-match scheduler and
/// a Core ML SD generation still honours the user's numbers.
struct PipelineBehaviorTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func makeSDPipeline(
        computeUnit: MLComputeUnits = .cpuAndNeuralEngine,
        controlNets: [String] = [],
        reduceMemory: Bool = false
    ) throws -> (pipeline: GenerationPipeline, model: SDModel) {
        let url = try temp.subdirectory("sd-model")
        try makeSDModelFixture(at: url)
        let model = try #require(SDModel(url: url, name: "sd-model", controlNet: []))
        let pipeline = GenerationPipeline.sd(
            model: model,
            computeUnit: computeUnit,
            controlNets: controlNets,
            reduceMemory: reduceMemory
        )
        return (pipeline, model)
    }

    // MARK: - Core ML Stable Diffusion

    @Test("A Core ML SD pipeline honours the requested step count and scheduler")
    func coreMLPassesRequestedValuesThrough() throws {
        let (pipeline, _) = try makeSDPipeline()

        #expect(pipeline.effectiveStepCount(requestedStepCount: 23) == 23)
        #expect(pipeline.effectiveScheduler(requestedScheduler: .pndmScheduler) == .pndmScheduler)
    }

    @Test("A Core ML SD pipeline exposes its Core ML specific configuration")
    func coreMLExposesComputeConfiguration() throws {
        let (pipeline, model) = try makeSDPipeline(
            computeUnit: .cpuAndGPU,
            controlNets: ["canny"],
            reduceMemory: true
        )

        #expect(pipeline.displayName == "sd-model")
        #expect(pipeline.coreMLModel == model)
        #expect(pipeline.mlComputeUnit == .cpuAndGPU)
        #expect(pipeline.controlNets == ["canny"])
        #expect(pipeline.reduceMemory)
    }

    @Test("A Core ML SD pipeline supports the full option set")
    func coreMLDeclaresFullCapabilities() throws {
        let (pipeline, _) = try makeSDPipeline()

        let capabilities = pipeline.generationCapabilities
        for capability in [
            GenerationCapabilities.negativePrompt, .startingImage, .strength, .stepCount,
            .guidanceScale, .scheduler, .controlNet,
        ] {
            #expect(capabilities.contains(capability))
        }
    }

    // MARK: - Iris FLUX.2 Klein

    @Test("Klein pins the step count to 4 regardless of what the user requested")
    func kleinPinsStepCount() {
        let pipeline = GenerationPipeline.iris(modelDir: "/models/klein", family: .fluxKlein)

        #expect(pipeline.effectiveStepCount(requestedStepCount: 20) == 4)
        #expect(pipeline.effectiveStepCount(requestedStepCount: 1) == 4)
    }

    @Test("Klein pins the scheduler to flow match")
    func kleinPinsScheduler() {
        let pipeline = GenerationPipeline.iris(modelDir: "/models/klein", family: .fluxKlein)

        #expect(
            pipeline.effectiveScheduler(requestedScheduler: .pndmScheduler)
                == .discreteFlowScheduler
        )
    }

    @Test("Klein exposes no Core ML compute configuration")
    func kleinHasNoCoreMLConfiguration() {
        let pipeline = GenerationPipeline.iris(modelDir: "/models/klein", family: .fluxKlein)

        #expect(pipeline.coreMLModel == nil)
        #expect(pipeline.mlComputeUnit == nil)
        #expect(pipeline.controlNets.isEmpty)
        #expect(pipeline.reduceMemory == false)
    }

    @Test("Klein supports a starting image but not ControlNet or guidance")
    func kleinDeclaresNarrowCapabilities() {
        let pipeline = GenerationPipeline.iris(modelDir: "/models/klein", family: .fluxKlein)

        let capabilities = pipeline.generationCapabilities
        #expect(capabilities.contains(.startingImage))
        #expect(!capabilities.contains(.controlNet))
        #expect(!capabilities.contains(.negativePrompt))
        #expect(!capabilities.contains(.guidanceScale))
        #expect(!capabilities.contains(.scheduler))
    }

    @Test("A pipeline is named after its model directory")
    func displayNameComesFromModelDirectory() {
        #expect(
            GenerationPipeline.iris(modelDir: "/models/klein", family: .fluxKlein).displayName
                == "klein"
        )
    }

    @Test("The family fallback name is currently unreachable")
    func displayNameFallbackIsUnreachable() {
        let fallback = GenerationPipeline.iris(modelDir: "", family: .fluxKlein).displayName

        // Known defect: `URL(fileURLWithPath: "")` resolves against the process
        // working directory, so `lastPathComponent` is never empty and
        // `IrisModelFamily.fallbackDisplayName` is dead code.
        #expect(fallback != "")
        withKnownIssue("An empty model path shows the working directory, not the family name") {
            #expect(fallback == IrisModelFamily.fluxKlein.fallbackDisplayName)
        }
    }

    @Test("An option is unresolved when the pipeline does not record it")
    func unrecordedOptionsResolveToNil() {
        // Z-Image-Turbo declares no metadata fields yet, so there is no effective
        // value to display for steps or scheduler.
        let pipeline = GenerationPipeline.iris(modelDir: "/models/z", family: .zImageTurbo)

        #expect(pipeline.effectiveStepCount(requestedStepCount: 20) == nil)
        #expect(pipeline.effectiveScheduler(requestedScheduler: .pndmScheduler) == nil)
    }
}

/// Compute unit selection is Core ML specific and moves into the Core ML
/// provider; the auto behaviour is the part users notice.
struct ComputeUnitPreferenceTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func makeModel(
        _ name: String,
        attention: SDModelAttentionType
    ) throws -> SDModel {
        let url = try temp.subdirectory(name)
        try makeSDModelFixture(at: url, attention: attention)
        return try #require(SDModel(url: url, name: name, controlNet: []))
    }

    @Test("Auto follows the model's attention type")
    func autoFollowsAttentionType() throws {
        let splitEinsum = try makeModel("split-einsum", attention: .splitEinsum)
        let original = try makeModel("original", attention: .original)

        #expect(
            ComputeUnitPreference.auto.computeUnits(forModel: splitEinsum) == .cpuAndNeuralEngine
        )
        #expect(ComputeUnitPreference.auto.computeUnits(forModel: original) == .cpuAndGPU)
    }

    @Test("An explicit preference overrides the model's attention type")
    func explicitPreferenceWins() throws {
        let model = try makeModel("split-einsum", attention: .splitEinsum)

        #expect(ComputeUnitPreference.cpuAndGPU.computeUnits(forModel: model) == .cpuAndGPU)
        #expect(ComputeUnitPreference.all.computeUnits(forModel: model) == .all)
    }
}
