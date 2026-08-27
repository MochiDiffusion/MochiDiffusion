//
//  EngineModel.swift
//  Mochi Diffusion
//

import Foundation

/// Feature flags that describe which generation controls a model supports.
///
/// The UI can use these to enable or disable controls, and generation paths can
/// use them to decide which request values are relevant for a given model.
nonisolated struct GenerationCapabilities: OptionSet, Sendable {
    let rawValue: UInt64

    static let negativePrompt = GenerationCapabilities(rawValue: 1 << 0)
    static let startingImage = GenerationCapabilities(rawValue: 1 << 1)
    static let strength = GenerationCapabilities(rawValue: 1 << 2)
    static let stepCount = GenerationCapabilities(rawValue: 1 << 3)
    static let guidanceScale = GenerationCapabilities(rawValue: 1 << 4)
    static let scheduler = GenerationCapabilities(rawValue: 1 << 5)
    static let controlNet = GenerationCapabilities(rawValue: 1 << 6)
}

nonisolated enum MetadataField: String, CaseIterable, Sendable {
    case prompt
    case negativePrompt
    case model
    case size
    case quality
    case startingImage
    case controlNetImage
    case inputImages
    case scheduler
    case mlComputeUnit
    case seed
    case steps
    case guidanceScale
}

/// Kept under its old name because Phase 4 replaces the capability half of it
/// with `OptionConstraints`; renaming it now would churn every call site twice.
nonisolated struct MochiModelConfig: Sendable {
    let generationCapabilities: GenerationCapabilities
    /// Metadata keys this model should embed in generated image metadata.
    let metadataFields: Set<MetadataField>

    func includesMetadataField(_ field: MetadataField) -> Bool {
        metadataFields.contains(field)
    }
}

/// A model a particular engine can generate with.
///
/// Identity is engine-qualified (``ModelID``), so two engines may expose the same
/// directory without discovery having to arbitrate which one owns it.
///
/// Phase staging, per `Multi-Engine-Design.md`:
///
/// - `config` holds today's capability flags. Phase 4 replaces that half of it
///   with per-model `OptionConstraints`.
/// - `url` is non-optional and `tokenizerModelDir` is still here because every
///   model today is a local directory. A hosted model has neither: `url` should
///   leave this protocol entirely once engines own their own path handling, and
///   prompt token counting needs to become something an engine provides rather
///   than a directory the UI tokenizes itself.
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var url: URL { get }
    var name: String { get }
    var config: MochiModelConfig { get }
    var promptTokenLimit: Int? { get }
    var tokenizerModelDir: URL? { get }
}
