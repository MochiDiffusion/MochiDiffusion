//
//  EngineModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated enum MetadataField: String, CaseIterable, Sendable {
    case prompt
    case negativePrompt
    case model
    /// Which engine generated the image, and its own key for the model.
    ///
    /// Recorded from Phase 2 rather than deferred, because engine identity exists
    /// now: every image generated before these keys land is unqualified legacy
    /// data forever, and the name-matching fallback would then have to cover our
    /// own recent output rather than only pre-engine history.
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
/// Phase staging, per `Multi-Engine-Design.md`:
///
/// - `url` is non-optional and `tokenizerModelDir` is still here because every
///   model today is a local directory. A hosted model has neither: `url` should
///   leave this protocol entirely once engines own their own path handling, and
///   prompt token counting needs to become something an engine provides rather
///   than a directory the UI tokenizes itself. Phase 6, when there will be two
///   implementations to design against instead of one.
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
