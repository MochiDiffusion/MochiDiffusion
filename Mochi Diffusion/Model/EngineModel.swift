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
/// Identity is engine-qualified (`ModelID`), so two engines may expose the same
/// directory without discovery having to arbitrate which one owns it.
///
/// Deliberately says nothing about where the model *is*. A local model has a
/// directory and a hosted one has only a name, so `url` is not a requirement
/// here: the two local model types keep theirs, and the only code that read one
/// generically — `ModelRepository.modelExists` — now takes a `URL` from the
/// engine that has one. An `Optional` requirement would have been worse, since
/// every caller would still have to handle a `nil` that means "wrong question".
///
/// `tokenizerModelDir` stays, and stays `Optional`, because `nil` is a real
/// answer rather than an absent one: it means "no local tokenizer", and the
/// prompt token counter already treats that as "no token count available".
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var name: String { get }
    /// What this model will and will not honour. Per model, not per engine: a
    /// Core ML model's size is fixed by how it was converted.
    var constraints: OptionConstraints { get }
    /// Metadata keys this model embeds in generated images.
    var metadataFields: Set<MetadataField> { get }
    var tokenizerModelDir: URL? { get }
}
