//
//  DrawThingsPresets.swift
//  Mochi Diffusion
//

import DrawThingsClient
import Foundation

/// Recommended configurations from a bundled snapshot of
/// https://models.drawthings.ai/configs.json (2026-11-13), refreshed each release.
/// A model with no entry of its own uses its family's.
nonisolated enum DrawThingsPresets {
    /// The allowlist: the Draw Things model versions Mochi offers, with the family
    /// name each image records as its architecture. A version Draw Things adds later
    /// appears only once it is added here.
    static let familyNames: [String: String] = [
        "v1": "Stable Diffusion 1.x",
        "v2": "Stable Diffusion 2.x",
        "sdxl_base_v0.9": "Stable Diffusion XL",
        "ssd_1b": "SSD-1B",
        "flux1": "FLUX.1",
        "flux2": "FLUX.2",
        "flux2_4b": "FLUX.2 Klein 4B",
        "flux2_9b": "FLUX.2 Klein 9B",
        "qwen_image": "Qwen Image",
        "z_image": "Z-Image",
        "hidream_i1": "HiDream I1",
        "krea_2": "Krea 2",
        "cosmos2.5_2b": "Cosmos 2.5 2B",
        "ernie_image": "ERNIE Image",
        "ideogram_4": "Ideogram 4",
    ]

    /// The bundled snapshot's entries that describe a model alone, without LoRAs or
    /// ControlNets. Read once per discovery pass rather than held in a static, so no
    /// non-`Sendable` dictionary lives in shared state.
    static func loadPresets() -> [[String: Any]] {
        guard let url = Bundle.main.url(forResource: "DrawThingsPresets", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let presets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return presets.filter {
            guard let config = $0["configuration"] as? [String: Any] else { return false }
            return (config["loras"] as? [Any] ?? []).isEmpty
                && (config["controls"] as? [Any] ?? []).isEmpty
        }
    }

    /// The configuration a model generates with before the sidebar's values are
    /// applied, or `nil` for a model Mochi does not offer.
    static func configuration(
        file: String, version: String, fields: [String: Any], presets: [[String: Any]]
    ) -> DrawThingsConfiguration? {
        guard familyNames[version] != nil else { return nil }
        let modifier = fields["modifier"] as? String ?? "none"
        let supportsTextOnly =
            modifier == "none"
            || (version.hasPrefix("flux2") && ["kontext", "kontext_kv"].contains(modifier))
        guard supportsTextOnly,
            !file.contains("_edit_"), !file.contains("_fill_"), !file.contains("_inpaint")
        else { return nil }
        let stem = modelStem(file)
        let selected =
            presets.first {
                let config = $0["configuration"] as? [String: Any]
                return modelStem(config?["model"] as? String ?? "") == stem
            } ?? presets.first { $0["version"] as? String == version }
        var config = DrawThingsConfiguration(model: file, numFrames: 1)
        // The values a preset leaves out. `DrawThingsConfiguration`'s own defaults
        // are Z-Image Turbo's; these are Draw Things' configuration defaults instead,
        // with the steps and guidance of a Stable Diffusion model.
        config.steps = 20
        config.guidanceScale = 7
        config.sampler = .dpmpp2mkarras
        config.shift = 1
        config.resolutionDependentShift = true
        if let values = selected?["configuration"] as? [String: Any] {
            apply(values, to: &config)
        } else {
            // The catalog has no v2 / SSD template. Use the client defaults, with
            // no T5 encoder or rectified-flow shift for these diffusion families.
            config.t5TextEncoder = false
            config.resolutionDependentShift = false
        }
        // A server's local filename/specification wins over a catalog preset's identity.
        config.model = file
        let defaultScale =
            (fields["default_scale"] as? NSNumber)?.intValue
            ?? (version == "v1" || version == "v2" ? 8 : 16)
        let size = Int32(min(16, max(8, defaultScale)) * 64)
        config.width = size
        config.height = size
        config.batchCount = 1
        config.batchSize = 1
        config.numFrames = 1
        config.seed = 0  // Overlaid with the queue's resolved seed immediately before encoding.
        return config
    }

    static func modelStem(_ file: String) -> String {
        file.replacingOccurrences(
            of: #"_(?:f16|q[0-9]+p|i8x|svd)(?=\.|_|$)"#,
            with: "", options: .regularExpression
        )
    }

    private static func apply(_ fields: [String: Any], to config: inout DrawThingsConfiguration) {
        if let value = fields["aestheticScore"] as? NSNumber {
            config.aestheticScore = value.floatValue
        }
        if let value = fields["causalInference"] as? NSNumber {
            config.causalInference = value.int32Value
        }
        if let value = fields["clipSkip"] as? NSNumber { config.clipSkip = value.int32Value }
        if let value = fields["compressionArtifacts"] as? NSNumber,
            let option = CompressionMethod(rawValue: value.int8Value)
        {
            config.compressionArtifacts = option
        }
        if let value = fields["compressionArtifactsQuality"] as? NSNumber {
            config.compressionArtifactsQuality = value.floatValue
        }
        if let value = fields["cropLeft"] as? NSNumber { config.cropLeft = value.int32Value }
        if let value = fields["cropTop"] as? NSNumber { config.cropTop = value.int32Value }
        if let value = fields["expandPromptToJson"] as? NSNumber {
            config.expandPromptToJson = value.boolValue
        }
        if let value = fields["guidanceEmbed"] as? NSNumber {
            config.guidanceEmbed = value.floatValue
        }
        if let value = fields["guidanceScale"] as? NSNumber {
            config.guidanceScale = value.floatValue
        }
        if let value = fields["hiresFix"] as? NSNumber { config.hiresFix = value.boolValue }
        if let value = fields["hiresFixHeight"] as? NSNumber {
            config.hiresFixHeight = value.int32Value
        }
        if let value = fields["hiresFixStrength"] as? NSNumber {
            config.hiresFixStrength = value.floatValue
        }
        if let value = fields["hiresFixWidth"] as? NSNumber {
            config.hiresFixWidth = value.int32Value
        }
        if let value = fields["maskBlur"] as? NSNumber { config.maskBlur = value.floatValue }
        if let value = fields["maskBlurOutset"] as? NSNumber {
            config.maskBlurOutset = value.int32Value
        }
        if let value = fields["negativeAestheticScore"] as? NSNumber {
            config.negativeAestheticScore = value.floatValue
        }
        if let value = fields["negativeOriginalImageHeight"] as? NSNumber {
            config.negativeOriginalImageHeight = value.int32Value
        }
        if let value = fields["negativeOriginalImageWidth"] as? NSNumber {
            config.negativeOriginalImageWidth = value.int32Value
        }
        if let value = fields["originalImageHeight"] as? NSNumber {
            config.originalImageHeight = value.int32Value
        }
        if let value = fields["originalImageWidth"] as? NSNumber {
            config.originalImageWidth = value.int32Value
        }
        if let value = fields["preserveOriginalAfterInpaint"] as? NSNumber {
            config.preserveOriginalAfterInpaint = value.boolValue
        }
        if let value = fields["refinerModel"] as? String { config.refinerModel = value }
        if let value = fields["refinerStart"] as? NSNumber {
            config.refinerStart = value.floatValue
        }
        if let value = fields["resolutionDependentShift"] as? NSNumber {
            config.resolutionDependentShift = value.boolValue
        }
        if let value = fields["sampler"] as? NSNumber,
            let option = SamplerType(rawValue: value.int8Value)
        {
            config.sampler = option
        }
        if let value = fields["seedMode"] as? NSNumber,
            let option = SeedMode(rawValue: value.int8Value)
        {
            config.seedMode = option
        }
        if let value = fields["separateClipL"] as? NSNumber {
            config.separateClipL = value.boolValue
        }
        if let value = fields["separateOpenClipG"] as? NSNumber {
            config.separateOpenClipG = value.boolValue
        }
        if let value = fields["separateT5"] as? NSNumber { config.separateT5 = value.boolValue }
        if let value = fields["sharpness"] as? NSNumber { config.sharpness = value.floatValue }
        if let value = fields["shift"] as? NSNumber { config.shift = value.floatValue }
        if let value = fields["speedUpWithGuidanceEmbed"] as? NSNumber {
            config.speedUpWithGuidanceEmbed = value.boolValue
        }
        if let value = fields["steps"] as? NSNumber { config.steps = value.int32Value }
        if let value = fields["strength"] as? NSNumber { config.strength = value.floatValue }
        if let value = fields["t5TextEncoder"] as? NSNumber {
            config.t5TextEncoder = value.boolValue
        }
        if let value = fields["targetImageHeight"] as? NSNumber {
            config.targetImageHeight = value.int32Value
        }
        if let value = fields["targetImageWidth"] as? NSNumber {
            config.targetImageWidth = value.int32Value
        }
        if let value = fields["teaCache"] as? NSNumber { config.teaCache = value.boolValue }
        if let value = fields["teaCacheEnd"] as? NSNumber { config.teaCacheEnd = value.int32Value }
        if let value = fields["teaCacheMaxSkipSteps"] as? NSNumber {
            config.teaCacheMaxSkipSteps = value.int32Value
        }
        if let value = fields["teaCacheStart"] as? NSNumber {
            config.teaCacheStart = value.int32Value
        }
        if let value = fields["teaCacheThreshold"] as? NSNumber {
            config.teaCacheThreshold = value.floatValue
        }
        if let value = fields["tiledDecoding"] as? NSNumber {
            config.tiledDecoding = value.boolValue
        }
        if let value = fields["tiledDiffusion"] as? NSNumber {
            config.tiledDiffusion = value.boolValue
        }
        if let value = fields["upscalerScaleFactor"] as? NSNumber {
            config.upscalerScaleFactor = value.int32Value
        }
        if let value = fields["zeroNegativePrompt"] as? NSNumber {
            config.zeroNegativePrompt = value.boolValue
        }
    }
}
