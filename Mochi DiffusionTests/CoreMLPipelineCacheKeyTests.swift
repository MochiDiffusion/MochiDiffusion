//
//  CoreMLPipelineCacheKeyTests.swift
//  Mochi DiffusionTests
//

import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

struct CoreMLPipelineCacheKeyTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    @Test("Identical SD 1.5 construction inputs reuse the pipeline")
    func identicalSD15InputsHaveTheSameKey() throws {
        let model = try makeModel(named: "sd15")
        let firstRequest = makeKey(model: model, disableSafety: false)
        let secondRequest = makeKey(model: model, disableSafety: false)

        #expect(firstRequest == secondRequest)
    }

    @Test("Changing SD 1.5 safety configuration rebuilds the pipeline")
    func sd15SafetyChangesTheKey() throws {
        let model = try makeModel(named: "sd15")
        let enabled = makeKey(model: model, disableSafety: false)
        let disabled = makeKey(model: model, disableSafety: true)

        #expect(enabled != disabled)
    }

    @Test("Safety configuration does not invalidate SDXL or SD3 pipelines")
    func newerModelSafetyDoesNotChangeTheKey() throws {
        let sdxl = try makeModel(
            named: "sdxl",
            extraUnetInputs: ["time_ids", "text_embeds"]
        )
        let sd3 = try makeModel(
            named: "sd3",
            extraUnetInputs: ["latent_image_embeddings"]
        )
        let sdxlEnabled = makeKey(model: sdxl, disableSafety: false)
        let sdxlDisabled = makeKey(model: sdxl, disableSafety: true)
        let sd3Enabled = makeKey(model: sd3, disableSafety: false)
        let sd3Disabled = makeKey(model: sd3, disableSafety: true)

        #expect(sdxlEnabled == sdxlDisabled)
        #expect(sd3Enabled == sd3Disabled)
    }

    private func makeModel(
        named name: String,
        extraUnetInputs: [String] = []
    ) throws -> SDModel {
        let url = temp.appending(name)
        try makeSDModelFixture(at: url, extraUnetInputs: extraUnetInputs)
        return try #require(SDModel(url: url, name: name, controlNet: []))
    }

    private func makeKey(model: SDModel, disableSafety: Bool) -> CoreMLPipelineCacheKey {
        CoreMLPipelineCacheKey(
            model: model,
            controlNet: ["controlnet"],
            effectiveControlNetLocation: "/models/controlnet",
            computeUnit: .cpuAndGPU,
            reduceMemory: true,
            disableSafety: disableSafety
        )
    }
}
