//
//  EngineModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated enum MetadataField: String, CaseIterable, Sendable {
    case prompt
    case negativePrompt
    case model
    /// The engine, and its own key for the model, so an imported image names a
    /// model exactly rather than by display name alone.
    case engine
    case modelKey
    case size
    case quality
    case startingImage
    case controlNetImage
    case inputImages
    case loras
    case scheduler
    case mlComputeUnit
    case seed
    case steps
    case guidanceScale
}

/// A server's LoRA filename and the weight used for an image, retained in metadata.
nonisolated struct LoRASelection: Codable, Equatable, Sendable, Identifiable {
    var file: String
    var weight: Float
    var id: String { file }
}

/// A model a particular engine can generate with.
///
/// Local models have a directory, but hosted ones only a name,
/// so the concrete types carry their own `url` and generic callers do not ask.
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var name: String { get }
    var constraints: OptionConstraints { get }
    var metadataFields: Set<MetadataField> { get }
    /// without a local tokenizer there is no prompt token count
    var tokenizerModelDir: URL? { get }
}
