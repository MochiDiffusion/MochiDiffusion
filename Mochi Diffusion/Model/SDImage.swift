//
//  SDImage.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/18/2022.
//

import AppKit
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import StableDiffusion

struct SDImage {
    var image: CGImage?
    var prompt = ""
    var negativePrompt = ""
    var width = 0
    var height = 0
    var model = ""
    var scheduler: StableDiffusionScheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
    var seed: UInt32 = 0
    var steps = 28
    var guidanceScale = 11.0
    var imageIndex = 0

    // Save image with metadata
    func save() {
        guard let img = image else {
            NSLog("*** Image was not valid!")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Image"
        panel.message = "Choose a folder and a name to store the image."
        panel.nameFieldLabel = "Image file name:"
        panel.nameFieldStringValue = "\(String(prompt.prefix(50))).\(seed).png"
        let resp = panel.runModal()
        if resp != .OK {
            return
        }
        
        guard let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard let data = CFDataCreateMutable(nil, 0) else { return }
        guard let destination = CGImageDestinationCreateWithData(data, (ext == "png" ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else { return }
        let iptc = [
            kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
            kCGImagePropertyIPTCCaptionAbstract: metadata(),
            kCGImagePropertyIPTCProgramVersion: "\(seed)"]
        let meta = [kCGImagePropertyIPTCDictionary: iptc]
        CGImageDestinationAddImage(destination, img, meta as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            // Try save image with metadata
            try (data as Data).write(to: url)
        } catch {
            NSLog("*** Error saving image file: \(error)")
        }
    }

    private func metadata() -> String {
        return title() + ", Seed: \(seed), Model: \(model), Scheduler: \(scheduler), Steps: \(steps), Guidance: \(guidanceScale), Index: \(imageIndex)"
    }

    private func title() -> String {
        return "Prompt: \(prompt), Negative: \(negativePrompt)"
    }
}
