//
//  DrawThingsEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import DrawThingsClient
import Foundation

/// One server for both this Mac (localhost) and another machine on the LAN.
/// Credentials are deliberately absent from this persisted value.
nonisolated struct DrawThingsConnection: Codable, Equatable, Sendable {
    var enabled = false
    var host = "localhost"
    var port = 7859
    var useTLS = true

    var secretAccount: String { "drawthings.\(host.lowercased()):\(port).\(useTLS)" }

    func validated() throws -> Self {
        var result = self
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.host.isEmpty,
            !result.host.contains(where: { $0.isWhitespace }),
            !result.host.contains("/"), !result.host.contains(":"),
            (1...65535).contains(port)
        else {
            throw DrawThingsError.message(
                "Enter a hostname or IPv4 address and a port from 1 to 65535.")
        }
        return result
    }
}

nonisolated enum DrawThingsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

nonisolated struct DrawThingsModel: EngineModel {
    let file: String
    let name: String
    /// The Draw Things model version, such as `flux2_4b`, which names its family.
    let version: String
    /// Distilled models with no guidance at all, from the catalog's
    /// `is_consistency_model`. They use neither guidance nor a negative prompt.
    let isConsistencyModel: Bool
    /// Models whose guidance is a distilled embedding rather than CFG, from the
    /// catalog's `guidance_embed`. Guidance still has an effect; a negative prompt
    /// does not.
    let usesGuidanceEmbedding: Bool
    let connection: DrawThingsConnection
    /// Preserve the full server specification, including fields unknown to this build.
    let specification: Data
    /// The model's recommended configuration, which supplies every value Mochi does
    /// not offer.
    let configuration: DrawThingsConfiguration

    var id: ModelID { ModelID(engine: .drawThings, key: file) }
    var tokenizerModelDir: URL? { nil }

    var supportsNegativePrompt: Bool { !isConsistencyModel && !usesGuidanceEmbedding }

    var recommendedSteps: Int? { Int(configuration.steps) }
    var recommendedGuidanceScale: Double? {
        isConsistencyModel ? nil : Double(configuration.guidanceScale)
    }

    var metadataFields: Set<MetadataField> {
        var fields: Set<MetadataField> = [
            .prompt, .model, .engine, .modelKey, .size, .seed, .steps,
        ]
        if supportsNegativePrompt { fields.insert(.negativePrompt) }
        if !isConsistencyModel { fields.insert(.guidanceScale) }
        return fields
    }

    /// Decided by the model alone, from catalog fields every family shares; no
    /// option depends on another option's value.
    var constraints: OptionConstraints {
        OptionConstraints(
            supportsNegativePrompt: supportsNegativePrompt,
            size: .freeform(range: 64...2048, step: 64),
            steps: .range(1...50, step: 1, acceptsBeyondUpperBound: true),
            guidanceScale: isConsistencyModel ? .unsupported : .range(1...20, step: nil),
            scheduler: .unsupported,
            startingImage: .unsupported,
            inputImages: .unsupported,
            controlNet: .unsupported,
            numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
            promptTokenLimit: nil
        )
    }
}

nonisolated struct DrawThingsPayload: Sendable {
    let connection: DrawThingsConnection
    let specification: Data
    /// Every value that will be sent except the seed, which the runtime sets per image.
    let configuration: DrawThingsConfiguration
    /// Empty when the model takes no negative prompt.
    let negativePrompt: String
    /// The model's family, recorded as its architecture.
    let architecture: String?
}

nonisolated struct DrawThingsEngine: GenerationEngineDescriptor {
    static let id = EngineID.drawThings
    static let modelListSource = ModelListSource.connection
    var displayName: String { "Draw Things" }
    private let secrets: any SecretStore
    private let transport: any DrawThingsTransport

    init(secrets: any SecretStore, transport: any DrawThingsTransport = GRPCDrawThingsTransport()) {
        self.secrets = secrets
        self.transport = transport
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard settings.drawThings.enabled else {
            return .needsConfiguration("Set up a Draw Things server in Settings")
        }
        do {
            _ = try settings.drawThings.validated()
            return .ready
        } catch {
            return .needsConfiguration(error.localizedDescription)
        }
    }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [DrawThingsModel] {
        guard context.settings.drawThings.enabled else { return [] }
        let connection = try context.settings.drawThings.validated()
        let catalog = try await transport.catalog(
            connection: connection, sharedSecret: secrets.secret(for: connection.secretAccount)
        )
        return try Self.models(from: catalog.models, connection: connection)
    }

    static func models(from data: Data, connection: DrawThingsConnection) throws
        -> [DrawThingsModel]
    {
        guard !data.isEmpty else {
            throw DrawThingsError.message(
                "The server publishes no models. Enable Model Browsing in Draw Things and download a model, then reconnect."
            )
        }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DrawThingsError.message("Draw Things returned an unreadable model list.")
        }
        var seen: Set<String> = []
        let presets = DrawThingsPresets.loadPresets()
        let models = entries.compactMap { entry -> DrawThingsModel? in
            guard let fields = entry as? [String: Any],
                let file = fields["file"] as? String, !file.isEmpty,
                let version = fields["version"] as? String,
                let configuration = DrawThingsPresets.configuration(
                    file: file, version: version, fields: fields, presets: presets),
                let specification = try? JSONSerialization.data(withJSONObject: [fields]),
                seen.insert(file).inserted
            else { return nil }
            return DrawThingsModel(
                file: file, name: fields["name"] as? String ?? file, version: version,
                isConsistencyModel: fields["is_consistency_model"] as? Bool ?? false,
                usesGuidanceEmbedding: fields["guidance_embed"] as? Bool ?? false,
                connection: connection, specification: specification, configuration: configuration
            )
        }
        guard !models.isEmpty else {
            throw DrawThingsError.message(
                "No supported text-to-image models were published. Enable Model Browsing in Draw Things and download a supported model, such as Krea 2, FLUX, Qwen Image or Z-Image. Video and editing models are not supported."
            )
        }
        return models
    }

    func plan(draft: GenerationDraft, model: DrawThingsModel) throws -> GenerationPlan<
        DrawThingsPayload
    > {
        let constraints = model.constraints
        var configuration = model.configuration
        let size = constraints.size.resolved(draft.configuredSize)
        configuration.width = Int32(size.width)
        configuration.height = Int32(size.height)
        // SDXL's size conditioning describes the image being made, so it follows the
        // output size rather than the recommended configuration's 1024. Other models
        // ignore these fields.
        configuration.originalImageWidth = Int32(size.width)
        configuration.originalImageHeight = Int32(size.height)
        configuration.targetImageWidth = Int32(size.width)
        configuration.targetImageHeight = Int32(size.height)
        if let steps = constraints.steps.resolved(draft.stepCount) {
            configuration.steps = Int32(steps)
        }
        let guidanceScale = constraints.guidanceScale.resolved(Double(draft.guidanceScale))
        if let guidanceScale {
            configuration.guidanceScale = Float(guidanceScale)
        }
        let numberOfImages =
            constraints.numberOfImages.resolved(draft.numberOfImages) ?? draft.numberOfImages
        return GenerationPlan(
            payload: DrawThingsPayload(
                connection: model.connection, specification: model.specification,
                configuration: configuration,
                negativePrompt: constraints.supportsNegativePrompt ? draft.negativePrompt : "",
                architecture: DrawThingsPresets.familyNames[model.version]
            ),
            size: size,
            startingImageData: nil, inputImageData: [], controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            stepCount: Int(configuration.steps), scheduler: nil, strength: nil,
            guidanceScale: guidanceScale.map(Float.init),
            numberOfImages: numberOfImages,
            mlComputeUnit: nil, startingImageName: nil, inputImageNames: []
        )
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        DrawThingsRuntime(secrets: secrets, transport: transport)
    }
}

actor DrawThingsRuntime: GenerationEngineRuntime {
    private let secrets: any SecretStore
    private let transport: any DrawThingsTransport

    init(secrets: any SecretStore, transport: any DrawThingsTransport) {
        self.secrets = secrets
        self.transport = transport
    }

    nonisolated func idleTimeout(for request: GenerationRequest) -> Duration? { .seconds(300) }

    func run(
        request: GenerationRequest, session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard let payload = request.payload as? DrawThingsPayload else {
            throw EngineError.payloadDoesNotBelongToEngine(engine: .drawThings)
        }
        let transport = transport
        let secret = secrets.secret(for: payload.connection.secretAccount)
        var seed = request.seed
        for _ in 0..<request.numberOfImages {
            if session.isCancelled { return }
            session.emit(.state(.loading("Generating with Draw Things…")))
            let imageSeed = seed
            let work = Task { () throws -> CGImage? in
                try await transport.generate(
                    payload: payload, prompt: request.prompt, seed: imageSeed,
                    sharedSecret: secret, session: session
                )
            }
            // Captures this image's task, including the race where cancellation
            // precedes registration.
            session.onCancel { work.cancel() }
            let image: CGImage?
            do {
                image = try await work.value
            } catch {
                if session.isCancelled { return }
                throw error
            }
            guard !session.isCancelled else { return }
            guard let image else {
                throw DrawThingsError.message("Draw Things returned no finished image.")
            }
            let metadata = Self.metadata(
                request: request, payload: payload, image: image, seed: imageSeed)
            guard let data = await metadata.pngData(for: image) else {
                throw GenerationError.malformedResponse
            }
            guard !session.isCancelled else { return }
            try await onResult(GenerationResult(metadata: metadata, imageData: data))
            seed = GenerationSeed.next(after: seed)
        }
    }

    /// Records the values sent to Draw Things, with `nil` for the options the
    /// model does not use.
    private static func metadata(
        request: GenerationRequest, payload: DrawThingsPayload, image: CGImage, seed: UInt32
    ) -> GenerationMetadata {
        let fields = request.metadataFields
        return GenerationMetadata(
            prompt: request.prompt,
            negativePrompt: fields.contains(.negativePrompt) ? payload.negativePrompt : nil,
            width: image.width,
            height: image.height,
            model: request.displayName,
            engine: request.modelID.engine.rawValue,
            modelKey: request.modelID.key,
            architecture: payload.architecture,
            startingImage: nil,
            strength: nil,
            controlNet: nil,
            controlNetImage: nil,
            inputImages: nil,
            scheduler: nil,
            mlComputeUnit: nil,
            seed: seed,
            steps: Int(payload.configuration.steps),
            guidanceScale: fields.contains(.guidanceScale)
                ? Double(payload.configuration.guidanceScale) : nil,
            generatedDate: Date(),
            metadataFields: fields
        )
    }
}
