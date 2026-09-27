//
//  ImageMetadata.swift
//  Mochi Diffusion
//

import AppKit
import CoreML
import Foundation
import ImageIO
import Musubi

// MARK: - Samplers

nonisolated extension Scheduler {
    /// The sampler name written to image metadata.
    ///
    /// DPM-Solver++ (second order, midpoint) and PNDM (PLMS steps only) are the
    /// samplers AUTOMATIC1111 calls `DPM++ 2M` and `PLMS`. Flow matching has no
    /// common name, so it keeps Mochi's own.
    var samplerLabel: String {
        switch self {
        case .dpmSolverMultistepScheduler: "DPM++ 2M"
        case .pndmScheduler: "PLMS"
        case .discreteFlowScheduler: displayName
        }
    }

    /// The scheduler a recorded sampler name stands for, or `nil` for a sampler
    /// Mochi does not offer.
    init?(samplerLabel: String) {
        if let scheduler = Scheduler(rawValue: samplerLabel) {
            self = scheduler
        } else if let scheduler = Scheduler.allCases.first(where: {
            $0.samplerLabel == samplerLabel
        }) {
            self = scheduler
        } else {
            return nil
        }
    }
}

// MARK: - Writing

nonisolated extension GenerationMetadata {
    /// This image as a Musubi snapshot: the source of both the native record
    /// and the AUTOMATIC1111 text written into the file.
    func snapshot(appVersion: String = NSApplication.appVersion) -> MochiGenerationSnapshot {
        var resources: [GenerationResource] = []
        if let controlNet { resources.append(GenerationResource(kind: .control, name: controlNet)) }

        var parameters: [GenerationParameter] = []
        if let architecture {
            parameters.append(GenerationParameter(key: "Architecture", value: architecture))
        }
        if let schedule = scheduleDetail {
            parameters.append(GenerationParameter(key: "Schedule", value: schedule))
        }

        return MochiGenerationSnapshot(
            producer: MetadataProducer(name: ImageMetadataReader.producerName, version: appVersion),
            generation: GenerationRecord(
                positivePrompt: prompt,
                negativePrompt: negativePrompt,
                model: model,
                sampler: scheduler?.samplerLabel,
                scheduler: stepSpacing,
                steps: steps,
                cfgScale: guidanceScale,
                seed: seed.map(String.init),
                dimensions: PixelDimensions(width: width, height: height),
                denoise: strength,
                generatedAt: generatedDate,
                resources: resources,
                parameters: parameters
            ),
            details: MochiGenerationDetails(
                engine: engine,
                modelKey: modelKey,
                quality: quality,
                computeUnit: mlComputeUnit.map(MLComputeUnits.toString),
                startingImage: startingImage,
                controlNetImage: controlNetImage,
                inputImages: inputImages
            )
        )
    }

    /// Core ML's DPM-Solver++ spaces its steps with Karras sigmas for SDXL and
    /// linearly otherwise. The other samplers have no separate spacing setting.
    private var stepSpacing: String? {
        guard engine == EngineID.coreMLStableDiffusion.rawValue,
            scheduler == .dpmSolverMultistepScheduler
        else { return nil }
        return architecture == SDModel.ModelType.sdxl.displayName ? "Karras" : "Linspace"
    }

    /// Fixed schedule settings that have no common field, kept in the native
    /// record only.
    private var scheduleDetail: String? {
        switch architecture {
        case SDModel.ModelType.sd3.displayName: "Flow shift 3.0"
        case IrisModelFamily.fluxKlein.displayName, IrisModelFamily.fluxKleinBase.displayName:
            "Flux shift"
        case IrisModelFamily.zImageTurbo.displayName: "Z-Image FlowMatch"
        default: nil
        }
    }

    /// `image` encoded as PNG with the native record and the
    /// AUTOMATIC1111-compatible text. Every engine encodes through here.
    ///
    /// Returns `nil` when the image or the native record cannot be written, so
    /// no image is saved without its record. AUTOMATIC1111 text that readers
    /// would misread is left out, and the native record alone is written.
    func pngData(for image: CGImage) async -> Data? {
        let snapshot = snapshot()
        guard let pixels = ImageMetadataWriter.encodePNG(image),
            let packet = try? MochiNativeCodec.encodeXMPPacket(snapshot)
        else { return nil }
        let parameters = A1111ParametersEncoder.encode(
            snapshot.generation, producer: snapshot.producer)
        return try? PNGMetadataWriter.write(
            PNGMetadataPayloads(nativeXMPPacket: packet, parameters: parameters.text),
            into: pixels,
            replacingExistingRecords: false
        )
    }
}

/// Encodes pixels and carries generation metadata into exported PNG files.
nonisolated enum ImageMetadataWriter {
    /// `image` as a PNG with no metadata.
    static func encodePNG(_ image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The file at `url` as PNG bytes.
    ///
    /// A PNG is copied unchanged, so its metadata survives exactly. Any other
    /// format is converted: its pixels are encoded as PNG, and its generation
    /// metadata is carried over. A released Mochi image keeps its settings as a
    /// native record with its original version. AUTOMATIC1111 text from another
    /// application is copied as it was. Other formats' records, such as Draw
    /// Things XMP, have no PNG carrier Mochi writes, so the PNG has none.
    static func exportPNG(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if CGImageSourceGetType(source) as String? == "public.png" {
            return try? Data(contentsOf: url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
            let pixels = encodePNG(image)
        else { return nil }
        guard let payloads = carriedPayloads(for: url) else { return pixels }
        return
            (try? PNGMetadataWriter.write(payloads, into: pixels, replacingExistingRecords: false))
            ?? pixels
    }

    private static func carriedPayloads(for url: URL) -> PNGMetadataPayloads? {
        let reading = ImageMetadataReader.read(url)
        guard case .selected(let reference) = reading?.selection, let reading else { return nil }
        let interpretation = reading.interpretations[reference.interpretation]
        let generation = interpretation.generations[reference.generation]

        switch interpretation.format {
        case .mochiDiffusion, .mochiDiffusionLegacyCaption:
            let snapshot = MochiGenerationSnapshot(
                producer: interpretation.producer
                    ?? MetadataProducer(name: ImageMetadataReader.producerName),
                generation: generation,
                details: ImageMetadataReader.mochiDetails(interpretation, reading: reading)
                    ?? MochiGenerationDetails()
            )
            guard let packet = try? MochiNativeCodec.encodeXMPPacket(snapshot) else { return nil }
            return PNGMetadataPayloads(
                nativeXMPPacket: packet,
                parameters: A1111ParametersEncoder.encode(generation, producer: snapshot.producer)
                    .text)
        case .automatic1111:
            let text = interpretation.payloadIndices.first.flatMap { reading.payloads[$0].text }
            return text.map { PNGMetadataPayloads(parameters: $0) }
        case .comfyUI, .drawThings:
            return nil
        }
    }
}

// MARK: - Reading

/// A setting the gallery shows but cannot restore, such as a sampler Mochi
/// does not offer or a seed too large for Mochi's seed field.
nonisolated struct MetadataDetail: Sendable, Hashable {
    let label: String
    let value: String
}

/// Reads generation metadata from image files through Musubi.
nonisolated enum ImageMetadataReader {
    static let producerName = "Mochi Diffusion"

    /// What one file's metadata says, before it becomes a gallery record.
    struct Reading {
        let payloads: [EmbeddedMetadataPayload]
        let interpretations: [MetadataInterpretation]
        let pixelSize: CGSize?

        var selection: GenerationSelection { GenerationSelection(interpretations) }
    }

    /// Reads the metadata of the file at `url`.
    ///
    /// PNG and JPEG are scanned by Musubi. When that finds no generation, as
    /// for HEIC or a JPEG whose caption ImageIO stored only as IPTC, ImageIO's
    /// XMP view of the file goes through the same Musubi codecs. Only metadata
    /// is read; pixels are not decoded.
    static func read(_ url: URL) -> Reading? {
        if let inspection = try? MetadataInspector.inspect(contentsOf: url),
            !inspection.interpretations.isEmpty
        {
            return Reading(
                payloads: inspection.payloads,
                interpretations: inspection.interpretations,
                pixelSize: CGSize(
                    width: inspection.imageDimensions.width,
                    height: inspection.imageDimensions.height))
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let pixelSize = (properties?[kCGImagePropertyPixelWidth] as? NSNumber).flatMap { width in
            (properties?[kCGImagePropertyPixelHeight] as? NSNumber).map {
                CGSize(width: width.intValue, height: $0.intValue)
            }
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
            let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data?
        else { return Reading(payloads: [], interpretations: [], pixelSize: pixelSize) }
        let payload = EmbeddedMetadataPayload(
            kind: .xmp, keyword: "XML:com.adobe.xmp", data: xmp,
            text: String(decoding: xmp, as: UTF8.self))
        return Reading(
            payloads: [payload],
            interpretations: MetadataInspector.interpret([payload]).interpretations,
            pixelSize: pixelSize)
    }

    /// The gallery record for the file at `url`, or `nil` when the file records
    /// no generation. An image with several equally plausible generations is
    /// kept with a note and no generation settings.
    static func record(for url: URL, fileDate: Date, finderTagColorNumber: Int) -> ImageRecord? {
        guard let reading = read(url) else { return nil }
        var record = ImageRecord.blank(
            path: url.path(percentEncoded: false),
            pixelSize: reading.pixelSize ?? .zero,
            fileDate: fileDate,
            finderTagColorNumber: finderTagColorNumber)

        switch reading.selection {
        case .none:
            return nil
        case .selected(let reference):
            let interpretation = reading.interpretations[reference.interpretation]
            apply(
                interpretation.generations[reference.generation],
                producer: interpretation.producer,
                format: interpretation.format,
                details: mochiDetails(interpretation, reading: reading),
                to: &record)
        case .ambiguous(let references):
            let sources = Set(
                references.map { generator(reading.interpretations[$0.interpretation]) })
            record.details = sources.sorted().map { MetadataDetail(label: "Generator", value: $0) }
            record.note = String(
                localized:
                    "This image records several generations, so Mochi shows none of their settings.",
                comment:
                    "Inspector note for an image whose metadata describes more than one generation")
        }
        return record
    }

    /// The gallery record of a freshly generated image, built the same way as
    /// one read back from its file.
    static func record(for metadata: GenerationMetadata, path: String, imageData: Data?)
        -> ImageRecord
    {
        let snapshot = metadata.snapshot()
        var record = ImageRecord.blank(
            path: path,
            pixelSize: CGSize(width: metadata.width, height: metadata.height),
            fileDate: metadata.generatedDate,
            finderTagColorNumber: 0)
        record.imageData = imageData
        apply(
            snapshot.generation, producer: snapshot.producer, format: .mochiDiffusion,
            details: snapshot.details,
            to: &record)
        return record
    }

    /// The Mochi details of a native record, or of a released Mochi caption's
    /// parameters.
    static func mochiDetails(_ interpretation: MetadataInterpretation, reading: Reading)
        -> MochiGenerationDetails?
    {
        switch interpretation.format {
        case .mochiDiffusion:
            guard let index = interpretation.payloadIndices.first,
                let text = reading.payloads[index].text
            else {
                return nil
            }
            return (try? MochiNativeCodec.decodeXMPPacket(text))?.details
        case .mochiDiffusionLegacyCaption:
            let generation = interpretation.generations.first
            func value(_ key: String) -> String? {
                generation?.parameters.first { $0.key == key }?.value
            }
            return MochiGenerationDetails(
                quality: value("Quality"),
                computeUnit: value("ML Compute Unit"),
                startingImage: value("Starting Image"),
                controlNetImage: value("ControlNet Image"),
                // Released captions join input images with commas.
                inputImages: value("Input Images").map {
                    $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                })
        case .automatic1111, .comfyUI, .drawThings:
            return nil
        }
    }

    /// Copies one generation into a gallery record. A value Mochi can restore
    /// becomes a field and is marked present. A value it cannot, such as an
    /// unknown sampler, becomes a detail that is only shown.
    static func apply(
        _ generation: GenerationRecord,
        producer: MetadataProducer?,
        format: MetadataFormat,
        details: MochiGenerationDetails?,
        to record: inout ImageRecord
    ) {
        var fields: Set<MetadataField> = []
        var shown: [MetadataDetail] = [
            MetadataDetail(label: "Generator", value: generator(producer: producer, format: format))
        ]

        if let prompt = generation.positivePrompt {
            record.prompt = prompt
            fields.insert(.prompt)
        }
        if let negativePrompt = generation.negativePrompt {
            record.negativePrompt = negativePrompt
            fields.insert(.negativePrompt)
        }
        if let model = generation.model {
            record.model = model
            fields.insert(.model)
        }
        if let dimensions = generation.dimensions {
            record.generationSize = CGSize(width: dimensions.width, height: dimensions.height)
            fields.insert(.size)
        }
        if let sampler = generation.sampler {
            if let scheduler = Scheduler(samplerLabel: sampler) {
                record.scheduler = scheduler
                fields.insert(.scheduler)
            } else {
                shown.append(MetadataDetail(label: "Sampler", value: sampler))
            }
        }
        if let schedule = generation.scheduler {
            shown.append(MetadataDetail(label: "Schedule", value: schedule))
        }
        if let steps = generation.steps {
            record.steps = steps
            fields.insert(.steps)
        }
        if let cfgScale = generation.cfgScale {
            record.guidanceScale = cfgScale
            fields.insert(.guidanceScale)
        }
        if let seed = generation.seed {
            if let value = UInt32(seed) {
                record.seed = value
                fields.insert(.seed)
            } else {
                shown.append(MetadataDetail(label: "Seed", value: seed))
            }
        }
        if let denoise = generation.denoise {
            record.strength = denoise
            fields.insert(.strength)
        }
        if let generatedAt = generation.generatedAt {
            record.generatedDate = generatedAt
            record.generatedDateIsRecorded = true
        }
        let loras = generation.resources.filter { $0.kind == .lora }.compactMap { resource in
            resource.name.map { name in resource.weight.map { "\(name) (\($0))" } ?? name }
        }
        if !loras.isEmpty {
            shown.append(MetadataDetail(label: "LoRAs", value: loras.joined(separator: "\n")))
        }

        if let details {
            if let engine = details.engine, let modelKey = details.modelKey {
                record.engine = engine
                record.modelKey = modelKey
                fields.formUnion([.engine, .modelKey])
            }
            if let quality = details.quality {
                record.quality = quality
                fields.insert(.quality)
            }
            if let computeUnit = details.computeUnit.flatMap(computeUnits(named:)) {
                record.mlComputeUnit = computeUnit
                fields.insert(.mlComputeUnit)
            }
            if let startingImage = details.startingImage {
                record.startingImage = startingImage
                fields.insert(.startingImage)
            }
            if let controlNetImage = details.controlNetImage {
                record.controlNetImage = controlNetImage
                fields.insert(.controlNetImage)
            }
            if let inputImages = details.inputImages {
                record.inputImages = inputImages
                fields.insert(.inputImages)
            }
        }

        record.metadataFields = fields
        record.details = shown
    }

    /// Only the names Mochi writes. Any other value is not a compute unit Mochi
    /// can restore.
    private static func computeUnits(named name: String) -> MLComputeUnits? {
        [MLComputeUnits.cpuOnly, .cpuAndGPU, .all, .cpuAndNeuralEngine].first {
            MLComputeUnits.toString($0) == name
        }
    }

    private static func generator(_ interpretation: MetadataInterpretation) -> String {
        generator(producer: interpretation.producer, format: interpretation.format)
    }

    /// The producer the metadata names, or the format when it names none.
    private static func generator(producer: MetadataProducer?, format: MetadataFormat) -> String {
        if let producer {
            return [producer.name, producer.version].compactMap { $0 }.joined(separator: " ")
        }
        switch format {
        case .automatic1111: return "AUTOMATIC1111-compatible"
        case .comfyUI: return "ComfyUI"
        case .drawThings: return "Draw Things"
        case .mochiDiffusion, .mochiDiffusionLegacyCaption: return producerName
        }
    }
}
