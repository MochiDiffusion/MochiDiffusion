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

    @MainActor
    @discardableResult
    /// Save image file to `pathURL`.
    /// File extension will be automatically added based on `type`.
    /// - Parameters:
    ///   - pathURL: Full save path without extension.
    ///   - type: Image type.
    /// - Returns: Full file save path with extension.
    func save(_ pathURL: URL, type: UTType) async -> URL? {
        guard let data = await imageData(type) else {
            NSLog("*** Failed to create image data")
            return nil
        }

        let url = pathURL.appendingPathExtension(for: type)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
        }

        return url
    }

    /// The file URL this image was read from or written to, when it has one.
    ///
    /// A freshly generated image that has not reached the images folder yet has no
    /// path and therefore no source file to copy.
    nonisolated var sourceURL: URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: false)
    }

    /// The formats the gallery can hold, and therefore the ones Save As can reproduce.
    /// Mirrors `ImageRepository.supportedImageExtensions`.
    nonisolated static let savableTypes: Set<UTType> = [.png, .jpeg, .heic]

    /// The image's own content type, taken from the file it came from.
    ///
    /// Save As deliberately does not let the user choose a different one. The output
    /// format is a single documented preference in Settings, which is what generation
    /// and Save All already use; offering a second, invisible choice here only made
    /// the saved bytes disagree with the saved name.
    ///
    /// Resolved through the system's extension mapping rather than `UTType.fromString`,
    /// which knows only each type's single preferred extension and so reports an
    /// imported `.jpg` as PNG. That helper still serves the import paths, where a
    /// PNG fallback is a reasonable guess; here it would mislabel bytes being copied.
    nonisolated var contentType: UTType {
        guard
            let sourceURL,
            let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased()),
            Self.savableTypes.contains(type)
        else { return .png }
        return type
    }

    @MainActor
    /// Display save image dialog.
    func saveAs() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
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
            try await writeCopy(to: url)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
        }
    }

    /// Writes this image to `destination` keeping the type and bytes it already has.
    ///
    /// Copies the source file whenever it is readable, so the saved image is byte
    /// identical and its recorded metadata survives exactly as written. Re-encoding is
    /// only a fallback for an image that has no file yet, where the resident pixels and
    /// every metadata field are genuinely current.
    nonisolated func writeCopy(to destination: URL) async throws {
        if let sourceURL, let data = try? Data(contentsOf: sourceURL) {
            try data.write(to: destination, options: .atomic)
            return
        }

        guard let data = await imageData(contentType) else {
            throw SDImageError.encodingFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Re-encodes the image with its metadata.
    ///
    /// Loads the file when no decoded image is resident which is normal for anything
    /// read from disk, only a freshly generated image arrives with its pixels.
    ///
    /// Deliberately re-encodes rather than copying the file, even though the file is
    /// usually identical: the caller chooses the type, so this is also the path that
    /// converts a PNG to JPEG on save.
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
