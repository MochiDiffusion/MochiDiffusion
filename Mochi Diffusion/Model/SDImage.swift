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
    var scheduler = Scheduler.dpmSolverMultistepScheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32 = 0
    var steps = 28
    var guidanceScale = 11.0
    var generatedDate = Date()
    /// Whether `generatedDate` is the recorded generation time rather than the
    /// file's modification date.
    var generatedDateIsRecorded = false
    /// Starting-image strength, when the image records one.
    var strength: Double?
    /// The size the metadata says the image was generated at, which can differ
    /// from the pixel size.
    var generationSize: CGSize?
    /// Settings shown but not restorable, such as an unknown sampler.
    var details: [MetadataDetail] = []
    /// Shown instead of settings when the metadata is ambiguous.
    var note: String?
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

    @MainActor
    /// Shows the save panel and writes the image as PNG where the user chooses.
    func saveAs() async {
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
            try await writeCopy(to: url)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
        }
    }

    /// Writes this image to `destination` as a PNG. See ``exportPNGData()``.
    nonisolated func writeCopy(to destination: URL) async throws {
        guard let data = await exportPNGData() else {
            throw SDImageError.encodingFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    /// This image's file as PNG bytes, for Save As, Save All and copying.
    ///
    /// A PNG is copied byte for byte, so its metadata survives exactly. A JPEG
    /// or HEIC is converted, carrying its generation metadata; see
    /// `ImageMetadataWriter.exportPNG(from:)`. An image with no file has no
    /// metadata to write, so it has no export.
    nonisolated func exportPNGData() async -> Data? {
        sourceURL.flatMap(ImageMetadataWriter.exportPNG(from:))
    }

    func getHumanReadableInfo(
        including metadataFields: Set<MetadataField> = Set(MetadataField.allCases)
    ) -> String {
        var lines = [
            generatedDateIsRecorded ? "\(Metadata.date.rawValue):" : "Modified:",
            generatedDate.formatted(date: .long, time: .standard),
        ]

        func append(_ title: String, value: String) {
            lines.append("")
            lines.append("\(title):")
            lines.append(value)
        }

        if let note {
            append("Note", value: note)
        }
        if metadataFields.contains(.model) {
            append(Metadata.model.rawValue, value: model)
        }
        if metadataFields.contains(.engine), !engine.isEmpty {
            append(Metadata.engine.rawValue, value: engine)
        }
        if metadataFields.contains(.size), let generationSize {
            append(
                Metadata.size.rawValue,
                value: "\(Int(generationSize.width)) x \(Int(generationSize.height))")
        }
        if metadataFields.contains(.quality), !quality.isEmpty {
            append(Metadata.quality.rawValue, value: quality)
        }
        if metadataFields.contains(.startingImage), !startingImage.isEmpty {
            append(Metadata.startingImage.rawValue, value: startingImage)
        }
        if metadataFields.contains(.strength), let strength {
            append("Strength", value: String(strength))
        }
        if metadataFields.contains(.controlNetImage), !controlNetImage.isEmpty {
            append(Metadata.controlNetImage.rawValue, value: controlNetImage)
        }
        if metadataFields.contains(.inputImages), !inputImages.isEmpty {
            append(
                Metadata.inputImages.rawValue,
                value: inputImages.map { Self.displayName(ofInputImage: $0) }.joined(
                    separator: ", "))
        }
        if metadataFields.contains(.prompt) {
            append(Metadata.includeInImage.rawValue, value: prompt)
        }
        if metadataFields.contains(.negativePrompt) {
            append(Metadata.excludeFromImage.rawValue, value: negativePrompt)
        }
        if metadataFields.contains(.seed) {
            append(Metadata.seed.rawValue, value: String(seed))
        }
        if metadataFields.contains(.steps) {
            append(Metadata.steps.rawValue, value: String(steps))
        }
        if metadataFields.contains(.guidanceScale) {
            append(Metadata.guidanceScale.rawValue, value: String(guidanceScale))
        }
        if metadataFields.contains(.scheduler) {
            append(Metadata.scheduler.rawValue, value: scheduler.displayName)
        }
        if metadataFields.contains(.mlComputeUnit) {
            append(Metadata.mlComputeUnit.rawValue, value: MLComputeUnits.toString(mlComputeUnit))
        }
        for detail in details {
            append(detail.label, value: detail.value)
        }

        return lines.joined(separator: "\n")
    }

    /// A reference image's name for display. A reference without a filename
    /// keeps its place in the list.
    static func displayName(ofInputImage name: String) -> String {
        name.isEmpty
            ? String(
                localized: "Unnamed image",
                comment: "Name shown for a reference image that had no filename")
            : name
    }
}
