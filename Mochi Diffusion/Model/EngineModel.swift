//
//  EngineModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated enum MetadataField: String, CaseIterable, Sendable {
    case prompt
    case negativePrompt
    case model
    /// Which engine generated the image, and that engine's own key for the model,
    /// so an imported image can name a model exactly rather than by display name
    /// alone.
    case engine
    case modelKey
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

/// A model a particular engine can generate with.
///
/// Identity is engine-qualified (``ModelID``), so two engines may expose the same
/// directory without discovery having to arbitrate which one owns it.
///
/// `url` is non-optional and `tokenizerModelDir` exists because every model is
/// currently a local directory. A hosted model would have neither, and both would
/// need to move behind the engine before one could be added.
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var url: URL { get }
    var name: String { get }
    /// What this model will and will not honour. Per model, not per engine: a
    /// Core ML model's size is fixed by how it was converted.
    var constraints: OptionConstraints { get }
    /// Metadata keys this model embeds in generated images.
    var metadataFields: Set<MetadataField> { get }
    var tokenizerModelDir: URL? { get }
}
