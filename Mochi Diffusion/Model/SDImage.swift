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
    ///
    /// It used to be read off `image` alone, which tied every size reader — gallery
    /// layout, the Info panel, the `Size:` metadata field — to a decoded image being
    /// resident. That is the assumption the thumbnail work removes, so the size is
    /// now a fact a caller can supply from a file's properties without decoding it.
    ///
    /// The fallback is what keeps that change additive. A generated image is built by
    /// assigning `image` and nothing else, in three separate runtimes; without it,
    /// every one of those would silently record `0x0` and the compiler would not say
    /// a word, because these have defaults.
    nonisolated var width: Int {
        get { storedWidth > 0 ? storedWidth : (image?.width ?? 0) }
        set { storedWidth = newValue }
    }
    nonisolated var height: Int {
        get { storedHeight > 0 ? storedHeight : (image?.height ?? 0) }
        set { storedHeight = newValue }
    }
    /// Not `private`: that would make the synthesised memberwise initialiser private
    /// too. Assign through `width`/`height`.
    nonisolated var storedWidth = 0
    nonisolated var storedHeight = 0
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
    var scheduler = Scheduler.dpmSolverMultistepScheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32 = 0
    var steps = 28
    var guidanceScale = 11.0
    var generatedDate = Date()
    var isUpscaling = false
    var path = ""
    var finderTagColorNumber = 0

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
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

    @MainActor
    /// Display save image dialog.
    func saveAs() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = String(localized: "Save Image", comment: "Header text for save image panel")
        panel.message = String(localized: "Choose a folder and a name to store the image")
        panel.nameFieldLabel = String(
            localized: "Image file name:", comment: "File name field label for save image panel")
        panel.nameFieldStringValue = filenameWithoutExtension()
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return
        }

        guard let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let type = UTType.fromString(ext)

        guard let data = await imageData(type) else {
            NSLog("*** Failed to create image data")
            return
        }

        do {
            try data.write(to: url)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
        }
    }

    /// Re-encodes the image with its metadata.
    ///
    /// Loads the file when no decoded image is resident, which is now the normal
    /// state for anything in the gallery: only a freshly generated image arrives with
    /// its pixels. Without this, Save As, Save All and Copy would each silently
    /// produce nothing for an image loaded from disk.
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
