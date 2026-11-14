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
    /// Draw Things on this Mac until the user enters another server. Mochi makes no
    /// network calls until Draw Things is switched on.
    var host = "localhost"
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

/// A LoRA the server publishes, with the specification it is sent back with.
nonisolated struct DrawThingsLoRA: Sendable {
    let option: LoRAOption
    /// The model version it was trained for, such as `flux2_4b`.
    let version: String
    /// The server's entry for this LoRA as a JSON object, sent back with a
    /// generation that uses it, including fields unknown to this build.
    let specification: Data

    /// The LoRAs in a server's list that Mochi can apply, in the server's order.
    ///
    /// Leaves out consistency, inpainting and alternative-decoder LoRAs, which
    /// need options Mochi does not offer.
    static func parse(_ data: Data) -> [Self] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard let fields = entry as? [String: Any],
                let file = fields["file"] as? String, !file.isEmpty,
                let version = fields["version"] as? String,
                fields["is_consistency_model"] as? Bool != true,
                fields["alternative_decoder"] == nil,
                (fields["modifier"] as? String ?? "none") == "none",
                let specification = try? JSONSerialization.data(withJSONObject: fields)
            else { return nil }
            let weight = fields["weight"] as? [String: Any]
            let lower = (weight?["lower_bound"] as? NSNumber)?.doubleValue ?? -1.5
            let upper = (weight?["upper_bound"] as? NSNumber)?.doubleValue ?? 2.5
            let value = (weight?["value"] as? NSNumber)?.doubleValue ?? 1
            guard lower.isFinite, upper.isFinite, value.isFinite, lower <= upper,
                seen.insert(file).inserted
            else { return nil }
            return Self(
                option: LoRAOption(
                    file: file, name: fields["name"] as? String ?? file,
                    triggerWords: fields["prefix"] as? String ?? "",
                    weightRange: lower...upper, defaultWeight: min(max(value, lower), upper)),
                version: version, specification: specification)
        }
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
    /// The server's LoRAs for this model's version.
    var loras: [DrawThingsLoRA] = []

    var id: ModelID { ModelID(engine: .drawThings, key: file) }
    var tokenizerModelDir: URL? { nil }
    var familyName: String? { DrawThingsPresets.familyNames[version] }
    var location: ModelLocation? { .server(name: connection.serverName, file: file) }

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
        // Mochi always runs a guidance-embedding model with the speed-up on, where
        // Draw Things uses the text guidance as the embed.
        return Double(configuration.guidanceScale)
    }

    var metadataFields: Set<MetadataField> {
        var fields: Set<MetadataField> = [
            .prompt, .model, .engine, .modelKey, .size, .seed, .steps, .loras,
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
            promptTokenLimit: nil,
            loras: loras.isEmpty
                ? .unsupported
                : .supported(
                    loras.map(\.option).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    })
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
    let previewFamily: ModelFamily
    /// The server's entries for the LoRAs in `configuration.loras`, as a JSON array.
    var loraSpecifications = Data()
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
        return try Self.models(from: catalog.models, connection: connection, loras: catalog.loras)
    }

    static func models(
        from data: Data, connection: DrawThingsConnection, loras: Data = Data()
    ) throws -> [DrawThingsModel] {
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
        let availableLoRAs = DrawThingsLoRA.parse(loras)
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
                connection: connection, specification: specification, configuration: configuration,
                loras: availableLoRAs.filter { $0.version == version }
            )
        }
        guard !models.isEmpty else {
            throw DrawThingsError.unusableModelList(
                "No supported models were published."
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
            // With the guidance embed speed-up on, Draw Things feeds the text guidance
            // into a guidance-embedding model's embed in a single pass and ignores
            // guidanceEmbed, so guidance always goes to guidanceScale.
            configuration.guidanceScale = Float(guidanceScale)
            if model.usesGuidanceEmbedding {
                configuration.speedUpWithGuidanceEmbed = true
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
        let loras = constraints.loras.resolved(draft.loras)
        configuration.loras = loras.map { LoRAConfig(file: $0.file, weight: Float($0.weight)) }
        let loraSpecifications = loras.compactMap { selection in
            model.loras.first { $0.option.file == selection.file }?.specification
        }
        return GenerationPlan(
            payload: DrawThingsPayload(
                connection: model.connection, specification: model.specification,
                configuration: configuration,
                negativePrompt: constraints.supportsNegativePrompt ? draft.negativePrompt : "",
                architecture: DrawThingsPresets.familyNames[model.version],
                previewFamily: ModelFamily.detect(from: model.version),
                loraSpecifications: Data("[".utf8)
                    + Data(loraSpecifications.joined(separator: Data(",".utf8)))
                    + Data("]".utf8)
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
            inputImageNames: references.names,
            loras: loras
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
            metadataFields: fields,
            // The shortest decimal text of each `Float` weight, as for strength.
            loras: payload.configuration.loras.map {
                LoRASelection(file: $0.file, weight: Double($0.weight.description) ?? 0)
            }
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
