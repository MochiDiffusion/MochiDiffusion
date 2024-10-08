//
//  SDImage.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/2022.
//

import AppKit
import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import UniformTypeIdentifiers

struct SDImage: Identifiable, Hashable {
    var id = UUID()
    var image: CGImage?
    var prompt = ""
    var negativePrompt = ""
    var width: Int { self.image?.width ?? 0 }
    var height: Int { self.image?.height ?? 0 }
    var aspectRatio: CGFloat = 0.0
    var model = ""
    var scheduler = Scheduler.dpmSolverMultistepScheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32 = 0
    var steps = 28
    var guidanceScale = 11.0
    var generatedDate = Date()
    var upscaler = ""
    var isUpscaling = false
    var path = ""
    var finderTagColorNumber = 0

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension SDImage {
    func filenameWithoutExtension() -> String {
        "\(String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(seed)"
    }

    func filenameWithoutExtension(count: Int) -> String {
        "\(String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(seed)"
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

    func imageData(_ type: UTType) async -> Data? {
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
        let iptc = await [
            kCGImagePropertyIPTCCaptionAbstract: metadata(),
            kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
            kCGImagePropertyIPTCProgramVersion: "\(await NSApplication.appVersion)",
        ]
        let meta = [kCGImagePropertyIPTCDictionary: iptc]
        CGImageDestinationAddImage(destination, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @MainActor
    func metadata() -> String {
        """
        \(Metadata.includeInImage.rawValue): \(prompt); \
        \(Metadata.excludeFromImage.rawValue): \(negativePrompt); \
        \(Metadata.model.rawValue): \(model); \
        \(Metadata.steps.rawValue): \(steps); \
        \(Metadata.guidanceScale.rawValue): \(guidanceScale); \
        \(Metadata.seed.rawValue): \(seed); \
        \(Metadata.size.rawValue): \(width)x\(height);
        """
            + (!upscaler.isEmpty ? " \(Metadata.upscaler.rawValue): \(upscaler); " : " ")
                + """
                \(Metadata.scheduler.rawValue): \(scheduler.rawValue); \
                \(Metadata.mlComputeUnit.rawValue): \(MLComputeUnits.toString(mlComputeUnit)); \
                \(Metadata.generator.rawValue): Mochi Diffusion \(NSApplication.appVersion)
                """
    }

    func getHumanReadableInfo() -> String {
        """
        \(Metadata.date.rawValue):
        \(generatedDate.formatted(date: .long, time: .standard))

        \(Metadata.model.rawValue):
        \(model)

        \(Metadata.size.rawValue):
        \(width) x \(height)\(!upscaler.isEmpty ? " (Upscaled using \(upscaler))" : "")

        \(Metadata.includeInImage.rawValue):
        \(prompt)

        \(Metadata.excludeFromImage.rawValue):
        \(negativePrompt)

        \(Metadata.seed.rawValue):
        \(seed)

        \(Metadata.steps.rawValue):
        \(steps)

        \(Metadata.guidanceScale.rawValue):
        \(guidanceScale)

        \(Metadata.scheduler.rawValue):
        \(scheduler.rawValue)

        \(Metadata.mlComputeUnit.rawValue):
        \(MLComputeUnits.toString(mlComputeUnit))
        """
    }
}
