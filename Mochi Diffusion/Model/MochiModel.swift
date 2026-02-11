//
//  MochiModel.swift
//  Mochi Diffusion
//

import Foundation

/// Feature flags that describe which generation controls a model supports.
///
/// The UI can use these to enable or disable controls, and generation paths can
/// use them to decide which request values are relevant for a given model.
struct GenerationCapabilities: OptionSet, Sendable {
    let rawValue: UInt64

    static let negativePrompt = GenerationCapabilities(rawValue: 1 << 0)
    static let startingImage = GenerationCapabilities(rawValue: 1 << 1)
    static let strength = GenerationCapabilities(rawValue: 1 << 2)
    static let stepCount = GenerationCapabilities(rawValue: 1 << 3)
    static let guidanceScale = GenerationCapabilities(rawValue: 1 << 4)
    static let scheduler = GenerationCapabilities(rawValue: 1 << 5)
    static let controlNet = GenerationCapabilities(rawValue: 1 << 6)
}

enum MetadataField: String, CaseIterable, Sendable {
    case prompt
    case negativePrompt
    case model
    case size
    case scheduler
    case mlComputeUnit
    case seed
    case steps
    case guidanceScale
}

struct MochiModelConfig: Sendable {
    let generationCapabilities: GenerationCapabilities
    /// Metadata keys this model should embed in generated image metadata.
    let metadataFields: Set<MetadataField>

    func includesMetadataField(_ field: MetadataField) -> Bool {
        metadataFields.contains(field)
    }
}

protocol MochiModel: Identifiable, Sendable {
    var url: URL { get }
    var name: String { get }
    var id: URL { get }
    var config: MochiModelConfig { get }
    var promptTokenLimit: Int? { get }
    var tokenizerModelDir: URL? { get }
}
