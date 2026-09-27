//
//  SDImage.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/2022.
//

import AppKit
import CoreML
import UniformTypeIdentifiers

struct SDImage: Identifiable, Hashable {
    var id = UUID()
    var image: CGImage?
    var prompt = ""
    var negativePrompt = ""
    /// The pixel size, stored when known and otherwise taken from `image`.
    /// A generated image can be built by assigning `image` and nothing else
    nonisolated var width: Int {
        get { storedWidth > 0 ? storedWidth : (image?.width ?? 0) }
        set { storedWidth = newValue }
    }
    nonisolated var height: Int {
        get { storedHeight > 0 ? storedHeight : (image?.height ?? 0) }
        set { storedHeight = newValue }
    }
    nonisolated private(set) var storedWidth = 0
    nonisolated private(set) var storedHeight = 0
    var aspectRatio: CGFloat = 0.0
    var model = ""
    /// The engine's stable id and its own key for the model, as strings, so an
    /// imported image can name a model exactly rather than by display name alone.
    var engine = ""
    var modelKey = ""
    var quality = ""
    var startingImage = ""
    var controlNetImage = ""
    var inputImages: [String] = []
    var loras: [LoRASelection] = []
    var scheduler = Scheduler.dpmSolverMultistepScheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32 = 0
    var steps = 28
    var guidanceScale = 11.0
    var generatedDate = Date()
    var path = ""
    var finderTagColorNumber = 0

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated enum SDImageError: Error, Equatable {
    /// No file to copy and the resident pixels could not be encoded.
    case encodingFailed
}

extension SDImage {
    func filenameWithoutExtension() -> String {
        imageFilenameWithoutExtension(prompt: prompt, seed: seed)
    }

    func filenameWithoutExtension(count: Int) -> String {
        imageFilenameWithoutExtension(prompt: prompt, seed: seed, count: count)
    }

    /// The file URL this image was read from or written to, when it has one.
    ///
    /// A freshly generated image that has not reached the images folder yet has no
    /// path and therefore no source file to copy.
    nonisolated var sourceURL: URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: false)
    }

    /// The formats the gallery can hold. Mirrors
    /// `ImageRepository.supportedImageExtensions`.
    nonisolated static let readableTypes: Set<UTType> = [.png, .jpeg, .heic]

    /// The image's own content type, taken from the file it came from.
    ///
    /// Resolved through the system's extension mapping, so `.jpg` and `.jpeg` are
    /// both JPEG.
    nonisolated var contentType: UTType {
        guard
            let sourceURL,
            let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased()),
            Self.readableTypes.contains(type)
        else { return .png }
        return type
    }

    @MainActor
    /// Display save image dialog.
    ///
    /// - Parameter metadataFields: the fields this image recorded, from the gallery,
    ///   written if the image has to be encoded rather than copied.
    func saveAs(metadataFields: Set<MetadataField>) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = String(localized: "Save Image", comment: "Header text for save image panel")
        panel.message = String(localized: "Choose a folder and a name to store the image")
        panel.nameFieldLabel = String(
            localized: "Image file name:", comment: "File name field label for save image panel")
        panel.nameFieldStringValue = filenameWithoutExtension()
        let resp = await ModalPresentation.present(panel)
        if resp != .OK {
            return
        }

        guard let url = panel.url else { return }

        do {
            try await writeCopy(to: url, metadataFields: metadataFields)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
        }
    }

    /// Writes this image to `destination` as a PNG.
    ///
    /// A readable PNG source file is copied, so the saved image is byte identical and
    /// its recorded metadata survives exactly as written. A JPEG or HEIC source, or an
    /// image with no file yet, is encoded as PNG carrying only `metadataFields`, so a
    /// field the image never recorded does not appear as a default value.
    nonisolated func writeCopy(
        to destination: URL,
        metadataFields: Set<MetadataField>
    ) async throws {
        if contentType == .png, let sourceURL, let data = try? Data(contentsOf: sourceURL) {
            try data.write(to: destination, options: .atomic)
            return
        }

        guard let data = await imageData(.png, metadataFields: metadataFields) else {
            throw SDImageError.encodingFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Re-encodes the image with its metadata.
    ///
    /// Loads the file when no decoded image is resident, which is normal for anything
    /// read from disk; only a freshly generated image arrives with its pixels.
    ///
    /// Re-encodes rather than copying the file because the caller chooses the type,
    /// so this is also the path that converts between formats.
    nonisolated func imageData(
        _ type: UTType,
        metadataFields: Set<MetadataField> = Set(MetadataField.allCases)
    ) async -> Data? {
        let image =
            self.image
            ?? (path.isEmpty
                ? nil : cgImageFromFileURL(URL(fileURLWithPath: path, isDirectory: false)))
        guard let image else { return nil }
        guard let data = CFDataCreateMutable(nil, 0) else { return nil }
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                type.identifier as CFString,
                1,
                nil
            )
        else { return nil }
        let iptc = [
            kCGImagePropertyIPTCCaptionAbstract: metadata(including: metadataFields),
            kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
            kCGImagePropertyIPTCProgramVersion: "\(NSApplication.appVersion)",
        ]
        let meta = [kCGImagePropertyIPTCDictionary: iptc]
        CGImageDestinationAddImage(destination, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated func metadata(including metadataFields: Set<MetadataField>) -> String {
        var pairs: [(key: Metadata, value: String)] = []

        if metadataFields.contains(.prompt) {
            pairs.append((.includeInImage, prompt))
        }
        if metadataFields.contains(.negativePrompt) {
            pairs.append((.excludeFromImage, negativePrompt))
        }
        if metadataFields.contains(.model) {
            pairs.append((.model, model))
        }
        if metadataFields.contains(.engine), !engine.isEmpty {
            pairs.append((.engine, engine))
        }
        if metadataFields.contains(.modelKey), !modelKey.isEmpty {
            pairs.append((.modelKey, modelKey))
        }
        if metadataFields.contains(.steps) {
            pairs.append((.steps, "\(steps)"))
        }
        if metadataFields.contains(.guidanceScale) {
            pairs.append((.guidanceScale, "\(guidanceScale)"))
        }
        if metadataFields.contains(.seed) {
            pairs.append((.seed, "\(seed)"))
        }
        if metadataFields.contains(.size) {
            pairs.append((.size, "\(width)x\(height)"))
        }
        if metadataFields.contains(.quality), !quality.isEmpty {
            pairs.append((.quality, quality))
        }
        if metadataFields.contains(.startingImage), !startingImage.isEmpty {
            pairs.append((.startingImage, startingImage))
        }
        if metadataFields.contains(.controlNetImage), !controlNetImage.isEmpty {
            pairs.append((.controlNetImage, controlNetImage))
        }
        if metadataFields.contains(.inputImages), !inputImages.isEmpty {
            // One line per image, so a filename may contain any character.
            pairs += inputImages.map { (key: Metadata.inputImages, value: $0) }
        }
        if metadataFields.contains(.loras), let data = try? JSONEncoder().encode(loras) {
            pairs.append((key: .loras, value: String(decoding: data, as: UTF8.self)))
        }
        if metadataFields.contains(.scheduler) {
            pairs.append((.scheduler, scheduler.rawValue))
        }
        if metadataFields.contains(.mlComputeUnit) {
            pairs.append((.mlComputeUnit, MLComputeUnits.toString(mlComputeUnit)))
        }

        // Generator/version is always emitted for import compatibility checks.
        pairs.append((.generator, "Mochi Diffusion \(NSApplication.appVersion)"))
        return MetadataCodec.encode(pairs)
    }

    func getHumanReadableInfo(
        including metadataFields: Set<MetadataField> = Set(MetadataField.allCases)
    ) -> String {
        var lines = [
            "\(Metadata.date.rawValue):",
            generatedDate.formatted(date: .long, time: .standard),
        ]

        func append(_ title: Metadata, value: String) {
            lines.append("")
            lines.append("\(title.rawValue):")
            lines.append(value)
        }

        if metadataFields.contains(.model) {
            append(.model, value: model)
        }
        if metadataFields.contains(.engine), !engine.isEmpty {
            append(.engine, value: engine)
        }
        if metadataFields.contains(.size) {
            append(.size, value: "\(width) x \(height)")
        }
        if metadataFields.contains(.quality), !quality.isEmpty {
            append(.quality, value: quality)
        }
        if metadataFields.contains(.startingImage), !startingImage.isEmpty {
            append(.startingImage, value: startingImage)
        }
        if metadataFields.contains(.controlNetImage), !controlNetImage.isEmpty {
            append(.controlNetImage, value: controlNetImage)
        }
        if metadataFields.contains(.inputImages), !inputImages.isEmpty {
            append(.inputImages, value: inputImages.joined(separator: ", "))
        }
        if metadataFields.contains(.loras), !loras.isEmpty {
            append(.loras, value: loras.map { "\($0.file) (\($0.weight))" }.joined(separator: ", "))
        }
        if metadataFields.contains(.prompt) {
            append(.includeInImage, value: prompt)
        }
        if metadataFields.contains(.negativePrompt) {
            append(.excludeFromImage, value: negativePrompt)
        }
        if metadataFields.contains(.seed) {
            append(.seed, value: String(seed))
        }
        if metadataFields.contains(.steps) {
            append(.steps, value: String(steps))
        }
        if metadataFields.contains(.guidanceScale) {
            append(.guidanceScale, value: String(guidanceScale))
        }
        if metadataFields.contains(.scheduler) {
            append(.scheduler, value: scheduler.displayName)
        }
        if metadataFields.contains(.mlComputeUnit) {
            append(.mlComputeUnit, value: MLComputeUnits.toString(mlComputeUnit))
        }

        return lines.joined(separator: "\n")
    }
}
