//
//  MetadataRoundTripTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Pins the metadata contract through real files: what a generated image writes
/// is what the gallery reads back, a value an image did not record stays absent,
/// and released or foreign images are read without invented values.
@MainActor
struct MetadataRoundTripTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    static func coreMLMetadata(
        prompt: String = "a cat wearing a hat",
        startingImage: String? = "starting.png",
        strength: Double? = 0.42
    ) -> GenerationMetadata {
        GenerationMetadata(
            prompt: prompt, negativePrompt: "blurry, low quality", width: 24, height: 16,
            model: "sdxl_1024x1024", engine: EngineID.coreMLStableDiffusion.rawValue,
            modelKey: "sdxl_1024x1024",
            architecture: SDModel.ModelType.sdxl.displayName, quality: nil,
            startingImage: startingImage,
            strength: strength, controlNet: "canny", controlNetImage: "control.png",
            inputImages: nil,
            scheduler: .dpmSolverMultistepScheduler, mlComputeUnit: .cpuAndNeuralEngine,
            seed: 123_456_789,
            steps: 17, guidanceScale: 7.5,
            generatedDate: Date(timeIntervalSince1970: 1_790_000_000.25),
            metadataFields: [])
    }

    /// Writes `metadata` through the generation encoder and reads the file back.
    func roundTrip(_ metadata: GenerationMetadata, name: String = "image") async throws
        -> ImageRecord
    {
        let data = try #require(await metadata.pngData(for: makeCGImage(width: 24, height: 16)))
        let url = temp.appending("\(name).png")
        try data.write(to: url, options: .atomic)
        return try #require(createImageRecordFromURL(url))
    }

    // MARK: - Generated images

    @Test("A Core ML image reads back every setting it recorded")
    func coreMLRoundTrip() async throws {
        let metadata = Self.coreMLMetadata()

        let record = try await roundTrip(metadata)

        #expect(record.prompt == metadata.prompt)
        #expect(record.negativePrompt == "blurry, low quality")
        #expect(record.model == metadata.model)
        #expect(record.engine == metadata.engine)
        #expect(record.modelKey == metadata.modelKey)
        #expect(record.startingImage == "starting.png")
        #expect(record.strength == 0.42)
        #expect(record.controlNetImage == "control.png")
        #expect(record.scheduler == .dpmSolverMultistepScheduler)
        #expect(record.mlComputeUnit == .cpuAndNeuralEngine)
        #expect(record.seed == 123_456_789)
        #expect(record.steps == 17)
        #expect(record.guidanceScale == 7.5)
        #expect(record.generationSize == CGSize(width: 24, height: 16))
        #expect(record.generatedDate == metadata.generatedDate)
        #expect(record.generatedDateIsRecorded)
        #expect(record.details.contains(MetadataDetail(label: "Schedule", value: "Karras")))
        #expect(
            record.metadataFields
                == [
                    .prompt, .negativePrompt, .model, .engine, .modelKey, .size, .startingImage,
                    .strength,
                    .controlNetImage, .scheduler, .mlComputeUnit, .seed, .steps, .guidanceScale,
                ])
    }

    @Test("A generated image's gallery record is the one its file reads back as")
    func freshRecordMatchesFile() async throws {
        let metadata = Self.coreMLMetadata()

        let read = try await roundTrip(metadata)
        let fresh = ImageMetadataReader.record(for: metadata, path: read.path, imageData: nil)

        #expect(fresh.metadataFields == read.metadataFields)
        #expect(fresh.details == read.details)
        #expect(fresh.strength == read.strength)
        #expect(fresh.generationSize == read.generationSize)
        #expect(fresh.generatedDate == read.generatedDate)
    }

    @Test("An empty prompt is recorded as empty, not as missing")
    func emptyPromptRoundTrip() async throws {
        let record = try await roundTrip(Self.coreMLMetadata(prompt: ""))

        #expect(record.metadataFields.contains(.prompt))
        #expect(record.prompt == "")
    }

    @Test("A generated PNG carries both the native record and the AUTOMATIC1111 text")
    func generatedPNGCarriesBothPayloads() async throws {
        let data = try #require(await Self.coreMLMetadata().pngData(for: makeCGImage()))

        #expect(data.range(of: Data("XML:com.adobe.xmp\0".utf8)) != nil)
        #expect(data.range(of: Data("parameters\0".utf8)) != nil)
        #expect(data.range(of: Data("Sampler: DPM++ 2M, Schedule type: Karras".utf8)) != nil)
    }

    @Test("An image without a starting image records no strength")
    func noStartingImageNoStrength() async throws {
        let record = try await roundTrip(Self.coreMLMetadata(startingImage: nil, strength: nil))

        #expect(!record.metadataFields.contains(.startingImage))
        #expect(!record.metadataFields.contains(.strength))
        #expect(record.strength == nil)
    }

    @Test("An Iris image keeps unnamed references in place and records no negative prompt")
    func irisRoundTrip() async throws {
        let metadata = GenerationMetadata(
            prompt: "a fox", negativePrompt: nil, width: 24, height: 16, model: "klein",
            engine: EngineID.iris.rawValue, modelKey: "klein",
            architecture: IrisModelFamily.fluxKlein.displayName,
            quality: nil, startingImage: nil, strength: nil, controlNet: nil, controlNetImage: nil,
            inputImages: ["cat.png", "", "dog.png"], scheduler: .discreteFlowScheduler,
            mlComputeUnit: nil,
            seed: 9, steps: 4, guidanceScale: 1, generatedDate: Date(), metadataFields: [])

        let record = try await roundTrip(metadata)

        #expect(record.inputImages == ["cat.png", "", "dog.png"])
        #expect(!record.metadataFields.contains(.negativePrompt))
        #expect(record.scheduler == .discreteFlowScheduler)
        #expect(record.guidanceScale == 1)
    }

    @Test("A hosted image records no seed, steps, sampler or guidance")
    func sparseHostedRoundTrip() async throws {
        let metadata = GenerationMetadata(
            prompt: "a bird", negativePrompt: nil, width: 24, height: 16, model: "gpt-image-2",
            engine: EngineID.openAI.rawValue, modelKey: "gpt-image-2", architecture: nil,
            quality: "high",
            startingImage: nil, strength: nil, controlNet: nil, controlNetImage: nil,
            inputImages: [],
            scheduler: nil, mlComputeUnit: nil, seed: nil, steps: nil, guidanceScale: nil,
            generatedDate: Date(),
            metadataFields: [])

        let record = try await roundTrip(metadata)

        #expect(
            record.metadataFields == [
                .prompt, .model, .engine, .modelKey, .size, .quality, .inputImages,
            ])
    }

    @Test(
        "Prompts the compatibility text cannot carry survive through the native record",
        arguments: [
            "a cat\nNegative prompt: typed\nSteps: 3",
            "line one\r\n  indented; with \"quotes\" <&>",
            "猫 🐈 unicode",
        ]
    )
    func hostilePromptsRoundTrip(prompt: String) async throws {
        let record = try await roundTrip(Self.coreMLMetadata(prompt: prompt))

        #expect(record.prompt == prompt)
    }

    // MARK: - Released and foreign images

    /// Writes an image the way released Mochi Diffusion did: an IPTC caption
    /// with the originating program and version.
    func writeReleasedImage(caption: String, type: UTType, name: String) throws -> URL {
        let url = temp.appending("\(name).\(type.preferredFilenameExtension!)")
        let data = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        let properties =
            [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: caption,
                    kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                    kCGImagePropertyIPTCProgramVersion: "6.0",
                ]
            ] as CFDictionary
        CGImageDestinationAddImage(destination, makeCGImage(), properties)
        precondition(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    @Test(
        "Released Mochi images stay readable in every format they were written in",
        arguments: [UTType.png, .jpeg, .heic])
    func releasedImagesAreReadable(type: UTType) throws {
        let caption = releasedCaption([
            (.includeInImage, "a cat; wearing a hat"),
            (.model, "sd-1.5"),
            (.steps, "17"),
            (.guidanceScale, "7.5"),
            (.seed, "42"),
            (.inputImages, "first.png, second.png"),
            (.scheduler, "PNDM"),
            (.mlComputeUnit, "CPU & GPU"),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let url = try writeReleasedImage(caption: caption, type: type, name: "released")

        let record = try #require(createImageRecordFromURL(url))

        // "; " ends a field only when a known label follows it.
        #expect(record.prompt == "a cat; wearing a hat")
        #expect(record.model == "sd-1.5")
        #expect(record.steps == 17)
        #expect(record.seed == 42)
        #expect(record.scheduler == .pndmScheduler)
        #expect(record.mlComputeUnit == .cpuAndGPU)
        #expect(record.inputImages == ["first.png", "second.png"])
        #expect(!record.metadataFields.contains(.negativePrompt))
        #expect(
            record.details.first == MetadataDetail(label: "Generator", value: "Mochi Diffusion 6.0")
        )
    }

    /// Writes a PNG whose only metadata is AUTOMATIC1111-compatible text.
    func writeParametersImage(_ text: String, name: String) throws -> URL {
        let url = temp.appending("\(name).png")
        try PNGTestChunks.write(textChunks: [("parameters", text)], to: url)
        return url
    }

    @Test("A foreign sampler, schedule or large seed is shown but never restored")
    func foreignValuesAreShownNotRestored() throws {
        let url = try writeParametersImage(
            "a cat\nSteps: 20, Sampler: Euler a, Schedule type: Karras, CFG scale: 6, Seed: 12345678901, Size: 8x8",
            name: "foreign")

        let record = try #require(createImageRecordFromURL(url))

        #expect(!record.metadataFields.contains(.scheduler))
        #expect(!record.metadataFields.contains(.seed))
        #expect(record.metadataFields.contains(.steps))
        #expect(
            record.details == [
                MetadataDetail(label: "Generator", value: "AUTOMATIC1111-compatible"),
                MetadataDetail(label: "Sampler", value: "Euler a"),
                MetadataDetail(label: "Schedule", value: "Karras"),
                MetadataDetail(label: "Seed", value: "12345678901"),
            ])
    }

    @Test("A foreign prompt keeps its LoRA tags and lists the LoRAs")
    func foreignLoRATags() throws {
        let url = try writeParametersImage(
            "a castle <lora:watercolor:0.8>\nSteps: 20, Seed: 1, Size: 8x8", name: "lora")

        let record = try #require(createImageRecordFromURL(url))

        #expect(record.prompt == "a castle <lora:watercolor:0.8>")
        #expect(record.details.contains(MetadataDetail(label: "LoRAs", value: "watercolor (0.8)")))
    }

    @Test("A generation graph with several samplers is imported with a note and no settings")
    func ambiguousGraphHasNoSettings() throws {
        let graph =
            #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"positive":["3",0]}},"#
            + #""2":{"class_type":"KSampler","inputs":{"seed":2,"positive":["3",0],"latent_image":["1",0]}},"#
            + #""3":{"class_type":"CLIPTextEncode","inputs":{"text":"a"}},"#
            + #""4":{"class_type":"SaveImage","inputs":{"images":["2",0]}}}"#
        let url = temp.appending("graph.png")
        try PNGTestChunks.write(textChunks: [("prompt", graph)], to: url)

        let record = try #require(createImageRecordFromURL(url))

        #expect(record.metadataFields.isEmpty)
        #expect(record.note != nil)
        #expect(record.details == [MetadataDetail(label: "Generator", value: "ComfyUI")])
    }

    @Test("A corrupt native record falls back to the compatibility text beside it")
    func corruptNativeFallsBack() throws {
        let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:mochi="https://github.com/MochiDiffusion/MochiDiffusion/ns/metadata/1.0/"><mochi:Generation>{"format":"mochi-diffusion",\
            "version":99}</mochi:Generation></rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let url = temp.appending("corrupt.png")
        try PNGTestChunks.write(
            textChunks: [
                ("XML:com.adobe.xmp", packet),
                ("parameters", "a cat\nSteps: 8, Seed: 7, Size: 8x8"),
            ],
            to: url)

        let record = try #require(createImageRecordFromURL(url))

        #expect(record.prompt == "a cat")
        #expect(record.seed == 7)
    }

    @Test("An image without generation metadata is not imported")
    func plainImageIsSkipped() throws {
        let url = temp.appending("plain.png")
        try PNGTestChunks.write(textChunks: [("Comment", "holiday")], to: url)

        #expect(createImageRecordFromURL(url) == nil)
    }
}

/// Writes a decodable PNG with extra uncompressed text chunks.
enum PNGTestChunks {
    static func write(textChunks: [(keyword: String, text: String)], to url: URL) throws {
        var data = try #require(ImageMetadataWriter.encodePNG(makeCGImage()))
        // After the 8-byte signature and the 25-byte IHDR chunk.
        var insertion = Data()
        for (keyword, text) in textChunks {
            var payload = Data(keyword.utf8)
            payload.append(contentsOf: [0, 0, 0, 0, 0])
            payload.append(Data(text.utf8))
            insertion.append(chunk(type: "iTXt", payload: payload))
        }
        data.insert(contentsOf: insertion, at: 33)
        try data.write(to: url, options: .atomic)
    }

    private static func chunk(type: String, payload: Data) -> Data {
        let typeData = Data(type.utf8)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typeData + payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc ^= 0xFFFF_FFFF
        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        result.append(typeData)
        result.append(payload)
        result.append(contentsOf: withUnsafeBytes(of: crc.bigEndian, Array.init))
        return result
    }
}
