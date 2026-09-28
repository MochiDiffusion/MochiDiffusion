//
//  CompatibilityTextTests.swift
//  Mochi DiffusionTests
//

import AppKit
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Musubi
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Pins the exact AUTOMATIC1111 text Mochi's generation and export paths write
/// for each engine and conversion. Musubi's wire probe checks that text of
/// these shapes with the pinned AUTOMATIC1111 and Civitai readers.
struct CompatibilityTextTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// The complete AUTOMATIC1111 text, or `nil` when none is written.
        let parameters: String?
        let bytes: @Sendable @MainActor (TempDirectory) async throws -> Data

        var testDescription: String { name }
    }

    static let software = "Software: Mochi Diffusion \(NSApplication.appVersion)"

    static func generated(_ name: String, _ metadata: GenerationMetadata, parameters: String?)
        -> Case
    {
        Case(name: name, parameters: parameters) { _ in
            try #require(await metadata.pngData(for: makeCGImage(width: 24, height: 16)))
        }
    }

    static func converted(
        _ name: String, type: UTType, parameters: String?,
        properties: @escaping @Sendable () -> [CFString: Any]
    ) -> Case {
        Case(name: name, parameters: parameters) { temp in
            let source = temp.appending("\(name).\(type.preferredFilenameExtension!)")
            let data = CFDataCreateMutable(nil, 0)!
            let destination = try #require(
                CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, makeCGImage(), properties() as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: source, options: .atomic)
            return try #require(ImageMetadataWriter.exportPNG(from: source))
        }
    }

    static func released(_ caption: String, version: String) -> [CFString: Any] {
        [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: caption,
                kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                kCGImagePropertyIPTCProgramVersion: version,
            ]
        ]
    }

    static func metadata(
        prompt: String = "a red cube on a table",
        negativePrompt: String? = "blurry",
        model: String,
        engine: EngineID = .coreMLStableDiffusion,
        architecture: String?,
        quality: String? = nil,
        startingImage: String? = nil,
        strength: Double? = nil,
        controlNet: String? = nil,
        controlNetImage: String? = nil,
        inputImages: [String]? = nil,
        scheduler: Scheduler?,
        mlComputeUnit: MLComputeUnits? = .cpuAndNeuralEngine,
        seed: UInt32?,
        steps: Int?,
        guidanceScale: Double?
    ) -> GenerationMetadata {
        GenerationMetadata(
            prompt: prompt, negativePrompt: negativePrompt, width: 24, height: 16, model: model,
            engine: engine.rawValue, modelKey: model, architecture: architecture,
            quality: quality, startingImage: startingImage, strength: strength,
            controlNet: controlNet, controlNetImage: controlNetImage, inputImages: inputImages,
            scheduler: scheduler, mlComputeUnit: mlComputeUnit, seed: seed, steps: steps,
            guidanceScale: guidanceScale,
            generatedDate: Date(timeIntervalSince1970: 1_790_000_000), metadataFields: [])
    }

    static let cases: [Case] = [
        // SDXL's DPM-Solver++ spaces its steps with Karras sigmas.
        generated(
            "coreml-sdxl",
            metadata(
                model: "sdxl-base", architecture: SDModel.ModelType.sdxl.displayName,
                scheduler: .dpmSolverMultistepScheduler, seed: UInt32.max, steps: 30,
                guidanceScale: 7),
            parameters: """
                a red cube on a table
                Negative prompt: blurry
                Steps: 30, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 7.0, \
                Seed: 4294967295, Size: 24x16, Model: sdxl-base, \(software)
                """),
        // The starting image's strength is recorded. ControlNet has no
        // AUTOMATIC1111 field outside its extension, so only the native record
        // names it.
        generated(
            "coreml-img2img-controlnet",
            metadata(
                model: "sd-1.5", architecture: SDModel.ModelType.sd15.displayName,
                startingImage: "start.png", strength: 0.6, controlNet: "canny",
                controlNetImage: "edges.png", scheduler: .pndmScheduler, seed: 42, steps: 20,
                guidanceScale: 7.5),
            parameters: """
                a red cube on a table
                Negative prompt: blurry
                Steps: 20, Sampler: PLMS, CFG scale: 7.5, Seed: 42, Size: 24x16, Model: sd-1.5, \
                Denoising strength: 0.6, \(software)
                """),
        // Flow matching has no AUTOMATIC1111 sampler name, so it is written
        // under Mochi's own.
        generated(
            "coreml-sd3",
            metadata(
                model: "sd3-medium", architecture: SDModel.ModelType.sd3.displayName,
                scheduler: .discreteFlowScheduler, seed: 7, steps: 28, guidanceScale: 5),
            parameters: """
                a red cube on a table
                Negative prompt: blurry
                Steps: 28, Sampler: Flow Match Euler Discrete, CFG scale: 5.0, Seed: 7, \
                Size: 24x16, Model: sd3-medium, \(software)
                """),
        // Reference images have no AUTOMATIC1111 field, and a model that takes
        // no negative prompt records none.
        generated(
            "iris-klein",
            metadata(
                negativePrompt: nil, model: "flux-klein", engine: .iris,
                architecture: IrisModelFamily.fluxKlein.displayName,
                inputImages: ["cat.png", "", "dog.png"], scheduler: .discreteFlowScheduler,
                mlComputeUnit: nil, seed: 9, steps: 4, guidanceScale: 1),
            parameters: """
                a red cube on a table
                Steps: 4, Sampler: Flow Match Euler Discrete, CFG scale: 1.0, Seed: 9, \
                Size: 24x16, Model: flux-klein, \(software)
                """),
        // A hosted record has no steps, seed or guidance, and none is invented.
        generated(
            "hosted",
            metadata(
                negativePrompt: nil, model: "gpt-image-2", engine: .openAI, architecture: nil,
                quality: "high", inputImages: [], scheduler: nil, mlComputeUnit: nil, seed: nil,
                steps: nil, guidanceScale: nil),
            parameters: "a red cube on a table\nSize: 24x16, Model: gpt-image-2, \(software)"),
        // An empty negative prompt is not written, the same as AUTOMATIC1111.
        // SD 1.x DPM-Solver++ spaces its steps linearly.
        generated(
            "unicode",
            metadata(
                prompt: "a café, 猫 🐈\nsecond line: \"blue\" \\ path", negativePrompt: "",
                model: "café, \"猫\"", architecture: SDModel.ModelType.sd15.displayName,
                scheduler: .dpmSolverMultistepScheduler, seed: 1, steps: 8, guidanceScale: 4.5),
            parameters: """
                a café, 猫 🐈
                second line: "blue" \\ path
                Steps: 8, Sampler: DPM++ 2M, Schedule type: Linspace, CFG scale: 4.5, Seed: 1, \
                Size: 24x16, Model: "café, \\"猫\\"", \(software)
                """),
        // A prompt containing a section marker would be misread, so only the
        // native record is written.
        generated(
            "markers",
            metadata(
                prompt: "a cube\nNegative prompt: part of the prompt\nSteps: 99, Seed: 123",
                model: "sd-1.5", architecture: SDModel.ModelType.sd15.displayName,
                scheduler: .pndmScheduler, seed: 42, steps: 20, guidanceScale: 7.5),
            parameters: nil),
        // A released caption converts to a native record and the text a fresh
        // image would write from the same values. The caption does not say
        // which step spacing ran, so no schedule is written.
        converted(
            "converted-6.0-jpeg", type: .jpeg,
            parameters: """
                a cat; wearing a hat
                Negative prompt: blurry
                Steps: 17, Sampler: DPM++ 2M, CFG scale: 7.5, Seed: 42, Size: 512x768, \
                Model: sd-1.5, Software: Mochi Diffusion 6.0
                """,
            properties: {
                released(
                    releasedCaption([
                        (.includeInImage, "a cat; wearing a hat"),
                        (.excludeFromImage, "blurry"),
                        (.model, "sd-1.5"),
                        (.steps, "17"),
                        (.guidanceScale, "7.5"),
                        (.seed, "42"),
                        (.size, "512x768"),
                        (.scheduler, "DPM-Solver++"),
                        (.mlComputeUnit, "CPU & GPU"),
                        (.generator, "Mochi Diffusion 6.0"),
                    ]), version: "6.0")
            }),
        converted(
            "converted-6.1-heic", type: .heic,
            parameters: """
                a fox
                in snow
                Steps: 4, CFG scale: 1.0, Seed: 9, Size: 1024x1024, Model: flux-klein, \
                Software: Mochi Diffusion 6.1.2
                """,
            properties: {
                released(
                    releasedLineCaption([
                        (.includeInImage, "a fox\nin snow"),
                        (.model, "flux-klein"),
                        (.engine, EngineID.iris.rawValue),
                        (.modelKey, "flux-klein"),
                        (.steps, "4"),
                        (.guidanceScale, "1"),
                        (.seed, "9"),
                        (.size, "1024x1024"),
                        (.inputImages, "first, one.png"),
                        (.generator, "Mochi Diffusion 6.1.2"),
                    ]), version: "6.1.2")
            }),
        // Another application's text is carried unchanged.
        converted(
            "converted-foreign-jpeg", type: .jpeg,
            parameters: """
                a dog
                Negative prompt: cat
                Steps: 12, Sampler: Euler a, CFG scale: 5, Seed: 9, Size: 8x8, Model: dreamshaper
                """,
            properties: {
                [
                    kCGImagePropertyExifDictionary: [
                        kCGImagePropertyExifUserComment:
                            "a dog\nNegative prompt: cat\nSteps: 12, Sampler: Euler a, CFG scale: 5, Seed: 9, Size: 8x8, Model: dreamshaper"
                    ]
                ]
            }),
    ]

    @Test("Each written image carries the expected AUTOMATIC1111 text", arguments: cases)
    @MainActor
    func compatibilityText(of testCase: Case) async throws {
        let temp = try TempDirectory()
        let bytes = try await testCase.bytes(temp)
        let url = temp.appending("\(testCase.name).png")
        try bytes.write(to: url, options: .atomic)

        let payloads = try MetadataInspector.inspect(bytes).payloads
        #expect(payloads.first { $0.keyword == "parameters" }?.text == testCase.parameters)
        #expect(createImageRecordFromURL(url) != nil)
    }
}
