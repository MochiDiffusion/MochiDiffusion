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
/// Says nothing about where the model is: a local model has a directory, a hosted
/// one has only a name, so the concrete types carry their own `url` and generic
/// callers do not ask.
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var name: String { get }
    /// What this model will and will not honour. Per model, not per engine: a
    /// Core ML model's size is fixed by how it was converted.
    var constraints: OptionConstraints { get }
    /// Metadata keys this model embeds in generated images.
    var metadataFields: Set<MetadataField> { get }
    /// `nil` means no local tokenizer, and so no prompt token count.
    var tokenizerModelDir: URL? { get }
}
