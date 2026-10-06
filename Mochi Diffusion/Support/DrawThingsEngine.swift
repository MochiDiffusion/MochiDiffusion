//
//  DrawThingsEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import DrawThingsClient
import Foundation
import os

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

    /// The host, with the port only when it is not Draw Things' default.
    var serverName: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }

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

/// What Settings says about the Draw Things model list: the result of the last
/// fetch. Mochi holds no connection between fetches and generations, so this
/// describes that fetch only, and stays true until the next one.
nonisolated struct DrawThingsStatus: Equatable, Sendable {
    nonisolated enum Fetch: Equatable, Sendable {
        case models(count: Int, at: Date)
        /// The server answered, but its list gives Mochi nothing to use; with why.
        case noModels(String, at: Date)
        case failed(String, at: Date)
    }

    /// Kept while the next fetch runs. `nil` before the first fetch from the server
    /// the settings name.
    var lastFetch: Fetch?
    var isFetching = false

    /// Switched off, or no host entered: Mochi does not fetch.
    static let inactive = DrawThingsStatus()
}

nonisolated enum DrawThingsError: LocalizedError, ModelListMayBeOutdated {
    case message(String)
    /// The server answered, but its model list gives Mochi nothing to use.
    case unusableModelList(String)
    /// The connection closed before the image was finished. Draw Things does this
    /// when the model is no longer installed, and it is also what quitting looks
    /// like, so Mochi cannot tell which.
    case connectionClosed(String)

    var errorDescription: String? {
        switch self {
        case .message(let message), .unusableModelList(let message),
            .connectionClosed(let message):
            message
        }
    }

    var outdatedModelListSource: ModelListSource? {
        if case .connectionClosed = self { .connection } else { nil }
    }
}

nonisolated struct DrawThingsModel: EngineModel {
    let file: String
    let name: String
    /// The Draw Things model version, such as `flux2_4b`, which names its family.
    let version: String
    /// The catalog's `modifier`, which says how the model uses an input image:
    /// `none` for a text-to-image model, `kontext` or `kontext_kv` for one that
    /// attends to reference images.
    let modifier: String
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

    /// A text-to-image model denoises from a starting image.
    var takesStartingImage: Bool { modifier == "none" }

    /// Draw Things passes these models its moodboard images, in order, as references.
    var takesReferenceImages: Bool { ["kontext", "kontext_kv"].contains(modifier) }

    /// Draw Things sets no limit of its own. These are Black Forest Labs' limits:
    /// ten for FLUX.2 dev, four for Klein.
    var maxReferenceImages: Int { version == "flux2" ? 10 : 4 }

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
        if takesStartingImage { fields.formUnion([.startingImage, .strength]) }
        if takesReferenceImages { fields.insert(.inputImages) }
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
            startingImage: takesStartingImage
                ? .supported(strength: .range(0...1, step: nil)) : .unsupported,
            inputImages: takesReferenceImages
                ? .supported(maxCount: maxReferenceImages) : .unsupported,
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
    /// How to turn the model's preview latents into colours.
    let previewFamily: LatentModelFamily
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
                modifier: fields["modifier"] as? String ?? "none",
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
        let startingImage = constraints.startingImage.prepared(draft.startingImage, scaledTo: size)
        let strength =
            startingImage.data.isEmpty
            ? nil : constraints.startingImage.strength.resolved(Double(draft.strength))
        // Strength 1 ignores the image, which is what generating without one means.
        configuration.strength = strength.map(Float.init) ?? 1
        let references = constraints.inputImages.prepared(draft.inputImages) { image, _ in
            Self.referenceSized(image, outputSize: size)
        }
        return GenerationPlan(
            payload: DrawThingsPayload(
                connection: model.connection, specification: model.specification,
                configuration: configuration,
                negativePrompt: constraints.supportsNegativePrompt ? draft.negativePrompt : "",
                architecture: DrawThingsPresets.familyNames[model.version],
                previewFamily: LatentModelFamily.detect(from: model.version)
            ),
            size: size,
            startingImageData: startingImage.data.first, inputImageData: references.data,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            stepCount: Int(configuration.steps), scheduler: nil,
            strength: strength.map(Float.init),
            guidanceScale: guidanceScale.map(Float.init),
            numberOfImages: numberOfImages,
            mlComputeUnit: nil, startingImageName: startingImage.names.first ?? nil,
            inputImageNames: references.names
        )
    }

    /// A reference scaled down to the output's pixel count, keeping its aspect
    /// ratio, or `nil` when it is no larger and is sent as it is.
    ///
    /// Never cropped to the output's shape: Draw Things scales each reference to
    /// the output's pixel count itself, keeping its aspect ratio
    /// (`encodeImageCond` in draw-things-community's `LocalImageGenerator`).
    /// Scaling down first sends no detail Draw Things would use, and keeps a
    /// photo's tensor from running to tens of megabytes.
    static func referenceSized(_ image: CGImage, outputSize: CGSize) -> CGImage? {
        let pixels = Double(image.width * image.height)
        let scale = (outputSize.width * outputSize.height / pixels).squareRoot()
        guard scale < 1 else { return nil }
        return image.scaledAndCroppedTo(
            size: CGSize(
                width: max(1, (Double(image.width) * scale).rounded()),
                height: max(1, (Double(image.height) * scale).rounded())))
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        DrawThingsRuntime(secrets: secrets, transport: transport)
    }
}

actor DrawThingsRuntime: GenerationEngineRuntime {
    private let logger = Logger()
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
        let inputs = try DrawThingsInputs(request: request)
        var seed = request.seed
        for _ in 0..<request.numberOfImages {
            if session.isCancelled { return }
            session.emit(.state(.loading("Generating with Draw Things…")))
            let imageSeed = seed
            let image: CGImage?
            do {
                image = try await transport.generate(
                    payload: payload, inputs: inputs, prompt: request.prompt, seed: imageSeed,
                    sharedSecret: secret, showsPreview: request.useDenoisedIntermediates,
                    session: session
                )
            } catch {
                if !session.isCancelled, !(error is CancellationError) {
                    // The alert shows a worded summary; the log keeps what happened.
                    logger.error("Draw Things generation failed: \(error)")
                }
                throw DrawThingsError.generationFailure(error, connection: payload.connection)
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
        let usedStartingImage = request.startingImageData != nil
        return GenerationMetadata(
            prompt: request.prompt,
            negativePrompt: fields.contains(.negativePrompt) ? payload.negativePrompt : nil,
            width: image.width,
            height: image.height,
            model: request.displayName,
            engine: request.modelID.engine.rawValue,
            modelKey: request.modelID.key,
            architecture: payload.architecture,
            startingImage: usedStartingImage ? request.startingImageName : nil,
            // The shortest decimal text of the `Float` is the value the user chose;
            // widening it exposes binary noise.
            strength: usedStartingImage ? request.strength.flatMap { Double($0.description) } : nil,
            controlNet: nil,
            controlNetImage: nil,
            // A reference without a filename keeps its place as an empty name.
            inputImages: request.inputImageData.isEmpty
                ? nil : request.inputImageNames.map { $0 ?? "" },
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
