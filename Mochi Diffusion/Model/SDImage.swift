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

struct SDImage: Identifiable {
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
}

extension SDImage {
    func save() {
        guard let image = image else {
            NSLog("*** Image was not valid!")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = String(localized: "Save Image", comment: "Header text for save image panel")
        panel.message = String(localized: "Choose a folder and a name to store the image")
        panel.nameFieldLabel = String(localized: "Image file name:", comment: "File name field label for save image panel")
        panel.nameFieldStringValue =
            "\(String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(seed).png"
        let resp = panel.runModal()
        if resp != .OK {
            return
        }

        guard let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard let data = CFDataCreateMutable(nil, 0) else { return }
        guard let destination = CGImageDestinationCreateWithData(
            data,
            (ext == "png" ?
                UTType.png.identifier :
                UTType.jpeg.identifier) as CFString,
            1,
            nil
        ) else { return }
        let iptc = [
            kCGImagePropertyIPTCCaptionAbstract: metadata(),
            kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
            kCGImagePropertyIPTCProgramVersion: "\(NSApplication.appVersion)"
        ]
        let meta = [kCGImagePropertyIPTCDictionary: iptc]
        CGImageDestinationAddImage(destination, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try (data as Data).write(to: url)
        } catch {
            NSLog("*** Error saving image file: \(error)")
        }
    }

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
        +
        (!upscaler.isEmpty ? " \(Metadata.upscaler.rawValue): \(upscaler); " : " ")
        +
        """
        \(Metadata.scheduler.rawValue): \(scheduler.rawValue); \
        \(Metadata.mlComputeUnit.rawValue): \(MLComputeUnits.toString(mlComputeUnit)); \
        \(Metadata.generator.rawValue): Mochi Diffusion \(NSApplication.appVersion)
        """
    }
}
