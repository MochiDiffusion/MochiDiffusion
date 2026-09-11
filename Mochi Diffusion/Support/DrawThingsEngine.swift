//
//  DrawThingsEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import DrawThingsClient
import Foundation
import UniformTypeIdentifiers

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

nonisolated struct DrawThingsLoRA: Identifiable, Sendable {
    let file: String
    let name: String
    let version: String
    let trigger: String
    let weightRange: ClosedRange<Float>
    let defaultWeight: Float
    let specification: Data
    var id: String { file }

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
                fields["modifier"] == nil || fields["modifier"] as? String == "none",
                let specification = try? JSONSerialization.data(withJSONObject: fields),
                seen.insert(file).inserted
            else { return nil }
            // Inpainting, consistency and alternate-decoder LoRAs need options this POC cannot express.
            let weight = fields["weight"] as? [String: Any]
            let lower = (weight?["lower_bound"] as? NSNumber)?.floatValue ?? -1.5
            let upper = (weight?["upper_bound"] as? NSNumber)?.floatValue ?? 2.5
            let value = (weight?["value"] as? NSNumber)?.floatValue ?? 1
            guard lower.isFinite, upper.isFinite, value.isFinite, lower <= upper else { return nil }
            return Self(
                file: file, name: fields["name"] as? String ?? file, version: version,
                trigger: fields["prefix"] as? String ?? "", weightRange: lower...upper,
                defaultWeight: min(max(value, lower), upper), specification: specification
            )
        }
    }
}

nonisolated struct DrawThingsModel: EngineModel {
    let file: String
    let name: String
    let connection: DrawThingsConnection
    /// Preserve the full server specification, including fields unknown to this build.
    let specification: Data
    let configuration: DrawThingsConfiguration
    var loras: [DrawThingsLoRA] = []

    var id: ModelID { ModelID(engine: .drawThings, key: file) }
    var tokenizerModelDir: URL? { nil }
    var metadataFields: Set<MetadataField> {
        [.prompt, .model, .engine, .modelKey, .size, .seed, .steps, .guidanceScale, .loras]
    }
    var constraints: OptionConstraints {
        OptionConstraints(
            supportsNegativePrompt: false,
            size: .freeform(range: 64...2048, step: 64),
            steps: .pinned(Int(configuration.steps)),
            guidanceScale: .pinned(Double(configuration.guidanceScale)),
            scheduler: .unsupported,
            startingImage: .unsupported,
            inputImages: .unsupported,
            controlNet: .unsupported,
            quality: .unsupported,
            numberOfImages: .pinned(1),
            promptTokenLimit: nil
        )
    }
}

nonisolated struct DrawThingsPayload: Sendable {
    let connection: DrawThingsConnection
    let specification: Data
    let configuration: DrawThingsConfiguration
    var loraSpecifications: Data = Data()
}

nonisolated struct DrawThingsEngine: GenerationEngineDescriptor {
    static let id = EngineID.drawThings
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
        return try Self.models(from: catalog.models, connection: connection, loras: catalog.loras)
    }

    static func models(from data: Data, connection: DrawThingsConnection, loras: Data = Data())
        throws -> [DrawThingsModel]
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
        let availableLoRAs = DrawThingsLoRA.parse(loras)
        let models = entries.compactMap { entry -> DrawThingsModel? in
            guard let fields = entry as? [String: Any],
                let file = fields["file"] as? String, !file.isEmpty,
                let version = fields["version"] as? String,
                let configuration = DrawThingsPresets.configuration(
                    file: file, version: version, fields: fields),
                let specification = try? JSONSerialization.data(withJSONObject: [fields]),
                seen.insert(file).inserted
            else { return nil }
            return DrawThingsModel(
                file: file, name: fields["name"] as? String ?? file,
                connection: connection, specification: specification, configuration: configuration,
                loras: availableLoRAs.filter { $0.version == version }
            )
        }
        guard !models.isEmpty else {
            throw DrawThingsError.message(
                "No supported text-to-image models were published. Enable Model Browsing and download an SD, SDXL, FLUX, Qwen Image, or Z-Image model. Video and editing models are excluded from this prototype."
            )
        }
        return models
    }

    func plan(draft: GenerationDraft, model: DrawThingsModel) throws -> GenerationPlan<
        DrawThingsPayload
    > {
        var configuration = model.configuration
        let size = model.constraints.size.resolved(draft.configuredSize)
        configuration.width = Int32(size.width)
        configuration.height = Int32(size.height)
        var specifications: [Any] = []
        var seen: Set<String> = []
        configuration.loras = try draft.loras.map { selection in
            guard let lora = model.loras.first(where: { $0.file == selection.file }),
                selection.weight.isFinite, lora.weightRange.contains(selection.weight),
                seen.insert(selection.file).inserted
            else {
                throw DrawThingsError.message(
                    "A selected LoRA is unavailable or has an invalid weight. Reconnect and select it again."
                )
            }
            specifications.append(try JSONSerialization.jsonObject(with: lora.specification))
            return LoRAConfig(file: lora.file, weight: selection.weight)
        }
        return GenerationPlan(
            payload: DrawThingsPayload(
                connection: model.connection, specification: model.specification,
                configuration: configuration,
                loraSpecifications: try JSONSerialization.data(withJSONObject: specifications)
            ),
            size: size,
            startingImageData: nil, inputImageData: [], controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            stepCount: Int(configuration.steps), scheduler: nil, strength: nil,
            guidanceScale: configuration.guidanceScale, quality: nil, numberOfImages: 1,
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
        if session.isCancelled { return }
        session.emit(.state(.loading("Generating with Draw Things…")))
        let transport = transport
        let secret = secrets.secret(for: payload.connection.secretAccount)
        let work = Task { () throws -> CGImage? in
            try await transport.generate(
                payload: payload, prompt: request.prompt, seed: request.seed,
                sharedSecret: secret, session: session
            )
        }
        // Captures this run's task, including the race where cancellation precedes registration.
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
        let metadata = GenerationMetadata(
            prompt: request.prompt, negativePrompt: "", width: image.width, height: image.height,
            model: request.displayName, engine: request.modelID.engine.rawValue,
            modelKey: request.modelID.key,
            quality: "", startingImage: "", controlNetImage: "", inputImages: [],
            // Excluded from metadataFields: DT's sampler is not Mochi's Core ML enum.
            scheduler: .dpmSolverMultistepScheduler, mlComputeUnit: nil, seed: request.seed,
            steps: Int(payload.configuration.steps),
            guidanceScale: Double(payload.configuration.guidanceScale),
            generatedDate: Date(), metadataFields: request.metadataFields,
            loras: payload.configuration.loras.map {
                LoRASelection(file: $0.file, weight: $0.weight)
            }
        )
        let data = try await Self.encode(
            image: image, metadata: metadata, imageType: request.imageType)
        guard !session.isCancelled else { return }
        try await onResult(
            GenerationResult(metadata: metadata, imageData: data, requestID: request.id))
    }

    @MainActor
    private static func encode(image: CGImage, metadata: GenerationMetadata, imageType: String)
        async throws -> Data
    {
        var result = SDImage(image: image, aspectRatio: 0, path: "")
        result.prompt = metadata.prompt
        result.model = metadata.model
        result.engine = metadata.engine
        result.modelKey = metadata.modelKey
        result.seed = metadata.seed
        result.steps = metadata.steps
        result.guidanceScale = metadata.guidanceScale
        result.loras = metadata.loras
        result.generatedDate = metadata.generatedDate
        guard
            let data = await result.imageData(
                UTType.fromString(imageType), metadataFields: metadata.metadataFields)
        else {
            throw GenerationError.malformedResponse
        }
        return data
    }
}
