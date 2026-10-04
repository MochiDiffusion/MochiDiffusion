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
    static let defaultPort = 7859
    /// The Keychain account of the server's shared secret. There is one server, so
    /// the account does not depend on the address: editing the host keeps the secret.
    static let secretAccount = "drawthings"

    var enabled = false
    /// Empty until the user enters a server. Mochi does not assume one.
    var host = ""
    var port = DrawThingsConnection.defaultPort
    var useTLS = true

    /// Whether Mochi may contact the server: switched on, with a host entered.
    /// Otherwise Mochi makes no network calls for Draw Things.
    var isActive: Bool { enabled && !host.isEmpty }

    /// Keeps the characters a hostname or IPv4 address can contain.
    static func filteredHost(_ text: String) -> String {
        text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Keeps up to five digits.
    static func filteredPort(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(5))
    }

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

/// Whether one generation reached the Draw Things server.
///
/// Reported by the runtime so Settings shows the result of Mochi's last contact
/// with the server, which can be a generation as well as a model-list fetch.
nonisolated struct DrawThingsContact: Sendable, Equatable {
    let connection: DrawThingsConnection
    /// Why the server could not be reached; `nil` when it answered, even with an
    /// error of its own.
    let failure: String?
}

/// What Settings says about the Draw Things server.
nonisolated enum DrawThingsStatus: Equatable, Sendable {
    /// Switched off, or no host entered: Mochi is not contacting a server.
    case inactive
    case connecting
    /// The server answered. A warning says why Mochi still cannot use it, such as a
    /// model list with no supported models.
    case connected(warning: String?)
    /// With the reason, to show under the status.
    case notConnected(String)
}

nonisolated enum DrawThingsError: LocalizedError {
    case message(String)
    /// The server answered, but its model list gives Mochi nothing to use.
    case unusableModelList(String)
    var errorDescription: String? {
        switch self {
        case .message(let message), .unusableModelList(let message): message
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
        guard !isConsistencyModel else { return nil }
        return Double(
            usesGuidanceEmbedding ? configuration.guidanceEmbed : configuration.guidanceScale)
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
    private let contacts: AsyncStream<DrawThingsContact>.Continuation?

    /// - Parameter contacts: where generations report whether they reached the
    ///   server; `nil` reports nothing.
    init(
        secrets: any SecretStore, transport: any DrawThingsTransport = GRPCDrawThingsTransport(),
        contacts: AsyncStream<DrawThingsContact>.Continuation? = nil
    ) {
        self.secrets = secrets
        self.transport = transport
        self.contacts = contacts
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard settings.drawThings.isActive else {
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
        guard context.settings.drawThings.isActive else { return [] }
        let connection = try context.settings.drawThings.validated()
        let catalog = try await transport.catalog(
            connection: connection,
            sharedSecret: secrets.secret(for: DrawThingsConnection.secretAccount)
        )
        return try Self.models(from: catalog.models, connection: connection)
    }

    static func models(from data: Data, connection: DrawThingsConnection) throws
        -> [DrawThingsModel]
    {
        guard !data.isEmpty else {
            throw DrawThingsError.unusableModelList(
                "The server publishes no models. Enable Model Browsing in Draw Things."
            )
        }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DrawThingsError.unusableModelList(
                "Draw Things returned an unreadable model list.")
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
            throw DrawThingsError.unusableModelList(
                "No supported models were published. Video and editing models are not supported."
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
            if model.usesGuidanceEmbedding {
                configuration.speedUpWithGuidanceEmbed = true
                configuration.guidanceEmbed = Float(guidanceScale)
            } else {
                configuration.guidanceScale = Float(guidanceScale)
            }
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
        DrawThingsRuntime(secrets: secrets, transport: transport, contacts: contacts)
    }
}

actor DrawThingsRuntime: GenerationEngineRuntime {
    private let secrets: any SecretStore
    private let transport: any DrawThingsTransport
    private let contacts: AsyncStream<DrawThingsContact>.Continuation?

    init(
        secrets: any SecretStore, transport: any DrawThingsTransport,
        contacts: AsyncStream<DrawThingsContact>.Continuation? = nil
    ) {
        self.secrets = secrets
        self.transport = transport
        self.contacts = contacts
    }

    nonisolated func idleTimeout(for request: GenerationRequest) -> Duration? { .seconds(300) }

    func run(
        request: GenerationRequest, session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard let payload = request.payload as? DrawThingsPayload else {
            throw EngineError.payloadDoesNotBelongToEngine(engine: .drawThings)
        }
        // One task for the batch, returning no image: the cancellation handler
        // must not retain completed tasks whose results hold full-size pixels.
        let work = Task {
            try await generateImages(
                request: request, payload: payload, session: session, onResult: onResult)
        }
        session.onCancel { work.cancel() }
        do {
            try await work.value
        } catch {
            if session.isCancelled { return }
            throw error
        }
    }

    private func generateImages(
        request: GenerationRequest, payload: DrawThingsPayload, session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        let secret = secrets.secret(for: DrawThingsConnection.secretAccount)
        var seed = request.seed
        for _ in 0..<request.numberOfImages {
            if session.isCancelled { return }
            session.emit(.state(.loading("Generating with Draw Things…")))
            let imageSeed = seed
            let image: CGImage?
            do {
                image = try await transport.generate(
                    payload: payload, prompt: request.prompt, seed: imageSeed,
                    sharedSecret: secret, session: session
                )
            } catch {
                // A stop says nothing about the server.
                if !session.isCancelled, !(error is CancellationError) {
                    report(error, connection: payload.connection)
                }
                throw error
            }
            contacts?.yield(DrawThingsContact(connection: payload.connection, failure: nil))
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

    /// An error Draw Things itself returned means the server answered, so only an
    /// unreachable server is reported as a failure.
    private func report(_ error: any Error, connection: DrawThingsConnection) {
        let failure =
            DrawThingsError.isUnreachable(error)
            ? DrawThingsError.connectionFailureDescription(error) : nil
        contacts?.yield(DrawThingsContact(connection: connection, failure: failure))
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
            samplerName: payload.configuration.sampler.displayName,
            mlComputeUnit: nil,
            seed: seed,
            steps: Int(payload.configuration.steps),
            guidanceScale: fields.contains(.guidanceScale)
                ? request.guidanceScale.map(Double.init) : nil,
            generatedDate: Date(),
            metadataFields: fields
        )
    }
}

nonisolated extension SamplerType {
    /// The name Draw Things gives this sampler, which is how an image records it:
    /// exactly `SamplerType.description` in draw-things-community
    /// (`Libraries/DataModels/Sources/Defaults.swift`), which Draw Things also
    /// parses back. Exhaustive, so a sampler added by a client update is named
    /// deliberately.
    var displayName: String {
        switch self {
        case .dpmpp2mkarras: "DPM++ 2M Karras"
        case .eulera: "Euler Ancestral"
        case .ddim: "DDIM"
        case .plms: "PLMS"
        case .dpmppsdekarras: "DPM++ SDE Karras"
        case .unipc: "UniPC"
        case .lcm: "LCM"
        case .eulerasubstep: "Euler A Substep"
        case .dpmppsdesubstep: "DPM++ SDE Substep"
        case .tcd: "TCD"
        case .euleratrailing: "Euler A Trailing"
        case .dpmppsdetrailing: "DPM++ SDE Trailing"
        case .dpmpp2mays: "DPM++ 2M AYS"
        case .euleraays: "Euler A AYS"
        case .dpmppsdeays: "DPM++ SDE AYS"
        case .dpmpp2mtrailing: "DPM++ 2M Trailing"
        case .ddimtrailing: "DDIM Trailing"
        case .unipctrailing: "UniPC Trailing"
        case .unipcays: "UniPC AYS"
        case .tcdtrailing: "TCD Trailing"
        }
    }
}
