//
//  ComputeUnitPreferenceTests.swift
//  Mochi DiffusionTests
//

import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Compute unit selection is Core ML specific and now happens inside
/// `CoreMLStableDiffusionEngine.plan`; the auto behaviour is the part users
/// notice.
///
/// No longer `@MainActor`: `ComputeUnitPreference` became `nonisolated` when the
/// engine started resolving it, exactly as §12.1 of the design document expected.
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
