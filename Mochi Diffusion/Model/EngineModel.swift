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
    case startingImage
    case controlNetImage
    case inputImages
    case strength
    case scheduler
    case mlComputeUnit
    case seed
    case steps
    case guidanceScale
    /// The LoRAs applied. An image that records this field and lists none was
    /// generated without LoRAs.
    case loras
}

/// Where a model lives, as the model info popover shows it.
nonisolated enum ModelLocation: Sendable, Equatable {
    /// A model directory on this Mac.
    case directory(URL)
    /// A model file on a Draw Things server, named as Settings names the server.
    case server(name: String, file: String)
}

/// A model a particular engine can generate with.
///
/// Local models have a directory, but a server's models only a name,
/// so the concrete types carry their own `url` and generic callers ask for
/// `location` instead.
nonisolated protocol EngineModel: Identifiable, Sendable {
    var id: ModelID { get }
    var name: String { get }
    var constraints: OptionConstraints { get }
    var metadataFields: Set<MetadataField> { get }
    /// without a local tokenizer there is no prompt token count
    var tokenizerModelDir: URL? { get }
    /// The steps the model's publisher recommends. Never applied automatically:
    /// steps are the sidebar's value until the user changes them. `nil` when there
    /// is no recommendation.
    var recommendedSteps: Int? { get }
    /// The guidance the model's publisher recommends, on the same terms as
    /// `recommendedSteps`. `nil` when there is no recommendation or the model does
    /// not use guidance.
    var recommendedGuidanceScale: Double? { get }
    /// The architecture's name, such as Stable Diffusion XL or FLUX.2 Klein, as
    /// image metadata records it. `nil` when it is not known.
    var familyName: String? { get }
    /// `nil` only for test doubles, which have nowhere to show.
    var location: ModelLocation? { get }
}

nonisolated extension EngineModel {
    /// Local models carry no recommendation.
    var recommendedSteps: Int? { nil }
    var recommendedGuidanceScale: Double? { nil }
    var familyName: String? { nil }
    var location: ModelLocation? { nil }
}
