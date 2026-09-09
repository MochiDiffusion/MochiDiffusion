//
//  OpenAIImageEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// A model offered by the OpenAI image API.
///
/// `name` doubles as the API's model identifier, and is also the `ModelID.key`, so
/// an image's recorded `modelKey` names the model exactly.
nonisolated struct OpenAIImageModel: EngineModel {
    let id: ModelID
    let name: String
    let constraints: OptionConstraints
    let metadataFields: Set<MetadataField>

    /// No local tokenizer, so the sidebar shows no token count. `nil` is a real
    /// answer here rather than a missing one.
    var tokenizerModelDir: URL? { nil }

    /// What to send as `model`.
    var apiName: String { id.key }
}

/// Image generation through the OpenAI API.
///
/// The credential store is taken at construction with no default, so every
/// construction site has to choose one. It lives on the descriptor because that is
/// the only place that can hand it to both `availability` and the runtime, which
/// `makeRuntime()` builds without settings.
///
/// The key never enters the payload: a payload rides in a `GenerationRequest`, which
/// is queued, logged and inspected. The runtime reads the key when it runs.
nonisolated struct OpenAIImageEngine: GenerationEngineDescriptor {
    typealias Model = OpenAIImageModel
    typealias Payload = OpenAIGenerationPayload

    static let id = EngineID.openAI
    var displayName: String { "OpenAI" }

    private let secrets: any SecretStore
    private let session: any HTTPSession

    init(secrets: any SecretStore, session: any HTTPSession = URLSessionHTTPSession()) {
        self.secrets = secrets
        self.session = session
    }

    /// The account name the credential is filed under. The engine id rather than
    /// anything user-visible, so renaming the display name cannot orphan a key.
    static var secretAccount: String { id.rawValue }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        // Existence, not the secret. This runs on every discovery pass.
        guard secrets.hasSecret(for: Self.secretAccount) else {
            return .needsConfiguration(
                String(
                    localized: "Add an API key in Settings",
                    comment: "Hosted engine unavailable because no API key is stored"
                )
            )
        }
        return .ready
    }

    /// A hand-maintained list. `/v1/models` returns everything the account can see
    /// and does not mark which models generate images, so it cannot drive a picker.
    ///
    /// Every entry has verified constraints: a wrong `SizeConstraint` produces
    /// requests the service rejects, or silently corrects sizes the user could
    /// have had. Add models by reading the current documentation, not by
    /// pattern-matching an existing entry.
    ///
    /// Ignores the models folder entirely, so an unreadable local directory
    /// cannot make this engine look broken.
    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [OpenAIImageModel] {
        [Self.gptImage2, Self.gptImage25Flare, Self.gptImage25Sunburst]
    }

    func plan(draft: GenerationDraft, model: OpenAIImageModel) throws
        -> GenerationPlan<OpenAIGenerationPayload>
    {
        let constraints = model.constraints
        let size = constraints.size.resolved(draft.configuredSize)
        let quality = constraints.quality.resolved(draft.quality)
        let numberOfImages =
            constraints.numberOfImages.resolved(draft.numberOfImages) ?? draft.numberOfImages
        // Reference images keep their cropped native resolution. Iris's fitting
        // is an engine-specific attention-budget workaround; the hosted API has
        // no equivalent local budget for us to predict or enforce.
        let inputs = constraints.inputImages.prepared(draft.inputImages) { _, _ in nil }

        return GenerationPlan(
            payload: OpenAIGenerationPayload(
                apiModel: model.apiName,
                size: size,
                // Non-optional in the payload for the same reason Core ML's
                // strength is: the request carries an optional so the queue knows
                // whether to draw a row, and the runtime wants the value it will
                // actually send.
                quality: quality ?? .auto,
                wantsPreviews: draft.showGenerationPreview
            ),
            size: size,
            inputImageData: inputs.data,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            // Nothing to invent: this service exposes no step count, sampler,
            // strength or guidance scale, and the plan says so rather than
            // coercing a value that metadata would then hide.
            stepCount: nil,
            scheduler: nil,
            strength: nil,
            guidanceScale: nil,
            quality: quality,
            numberOfImages: numberOfImages,
            mlComputeUnit: nil,
            startingImageName: nil,
            inputImageNames: inputs.names
        )
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        OpenAIEngineRuntime(
            secrets: secrets,
            account: Self.secretAccount,
            session: session
        )
    }
}

// MARK: - The model list

nonisolated extension OpenAIImageEngine {
    /// An app safety limit, not a documented service limit. It bounds multi-file
    /// drops and is high enough to exercise substantial reference sets without
    /// claiming Mochi can safely ingest an arbitrary selection.
    static let maxInputImages = 16

    /// Limits read from the image generation guide on 2026-09-09. GPT Image 2
    /// and both GPT Image 2.5 variants share this geometry.
    ///
    /// The per-dimension floor is derived rather than quoted: the guide gives a
    /// total-pixel minimum and a 3:1 ratio cap but no per-edge minimum, and the
    /// smallest edge any legal size can have is the one where the long edge is
    /// exactly three times it — `3s² >= 655_360`, so `s >= 468`, which is 480 on
    /// the 16px grid. A floor of 512 would have excluded legal sizes like
    /// 480x1440.
    private static func imageModel(
        apiName: String,
        qualities: [ImageQuality]
    ) -> OpenAIImageModel {
        OpenAIImageModel(
            id: ModelID(engine: OpenAIImageEngine.id, key: apiName),
            name: apiName,
            constraints: OptionConstraints(
                supportsNegativePrompt: false,
                size: .freeform(
                    range: 480...3_840,
                    step: 16,
                    limits: SizeLimits(
                        maxAspectRatio: 3,
                        pixelBounds: 655_360...8_294_400
                    )
                ),
                steps: .unsupported,
                guidanceScale: .unsupported,
                scheduler: .unsupported,
                startingImage: .unsupported,
                inputImages: .supported(maxCount: maxInputImages),
                controlNet: .unsupported,
                quality: .oneOf(qualities),
                // Ours to choose, not the API's: one request is sent per image,
                // so this bounds our own loop. Tighter than the local engines'
                // 1...100, with no room above it, because every image here is
                // billed.
                numberOfImages: .range(1...10, step: 1),
                promptTokenLimit: nil
            ),
            // No `.seed`: the service exposes no seed, so recording one would put
            // a number in the metadata that had no effect on the image. A seed is
            // still generated for the output filename, which is all it is used
            // for here.
            //
            // No `.revisedPrompt` either. The API may return a revision, but that
            // is documented on the Responses API image tool rather than this
            // endpoint, and an unverified metadata key is a permanent export
            // contract for a guess.
            metadataFields: [
                .prompt, .model, .engine, .modelKey, .size, .quality, .inputImages,
            ]
        )
    }

    static let gptImage2 = imageModel(
        apiName: "gpt-image-2",
        qualities: [.auto, .low, .medium, .high]
    )

    static let gptImage25Flare = imageModel(
        apiName: "gpt-image-2.5-flare",
        qualities: [.auto, .low, .medium, .high, .xhigh, .max]
    )

    static let gptImage25Sunburst = imageModel(
        apiName: "gpt-image-2.5-sunburst",
        qualities: [.auto, .low, .medium, .high, .xhigh, .max]
    )
}

/// What this engine's generation needs beyond the values every engine reports.
///
/// Carries no credential. See ``OpenAIImageEngine``.
nonisolated struct OpenAIGenerationPayload: Sendable {
    let apiModel: String
    let size: CGSize
    let quality: ImageQuality
    /// Whether to ask for streamed partial images. Maps
    /// `showGenerationPreview` onto this API's `partial_images`.
    let wantsPreviews: Bool
}
