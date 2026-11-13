//
//  DrawThingsTransport.swift
//  Mochi Diffusion
//

import CoreGraphics
import CryptoKit
import DrawThingsClient
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization

extension DrawThingsError {
    /// Whether `error` means there is no connection to the server, rather than that
    /// it answered with an error of its own: Mochi could not connect, or the
    /// connection closed during a call.
    static func isUnreachable(_ error: any Error) -> Bool {
        isConnectionFailure(error) || (error as? RPCError)?.code == .unavailable
    }

    /// Mochi could not open a connection, so the call never started.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        error is DrawThingsUnopenedCall
    }

    /// A failed generation's error, worded for the generation alert. Other errors,
    /// including Draw Things' own, keep their text.
    static func generationFailure(_ error: any Error, connection: DrawThingsConnection)
        -> any Error
    {
        if isConnectionFailure(error) {
            return DrawThingsError.message(
                String(
                    localized: "Couldn't reach the Draw Things server at \(connection.serverName).",
                    comment: "Generation error when the Draw Things server cannot be reached"
                ))
        }
        guard let status = error as? RPCError else { return error }
        if isUnreachable(error) {
            return DrawThingsError.connectionClosed(
                String(
                    localized:
                        "Draw Things closed the connection before the image was finished.",
                    comment: "Generation error when the connection closes during a generation"
                ))
        }
        let detail = status.message.isEmpty ? "\(status.code)" : status.message
        return DrawThingsError.message(
            String(
                localized: "Draw Things reported an error: \(detail)",
                comment: "Generation error passing on the text Draw Things returned"
            ))
    }

    /// What Settings shows when Mochi could not use the server.
    static func connectionFailureDescription(_ error: any Error) -> String {
        guard isUnreachable(error) else { return error.localizedDescription }
        return String(
            localized:
                "The server didn't answer. It isn't available or its TLS setting doesn't match.",
            comment:
                "Reason shown under 'Not connected' when the Draw Things server cannot be reached"
        )
    }
}

/// A call that failed before its stream opened, because the connection never did
/// or its deadline passed first. The server has not seen the request.
nonisolated struct DrawThingsUnopenedCall: Error {
    var error: RPCError
}

nonisolated struct DrawThingsCatalog: Sendable {
    var models: Data
    var loras = Data()
}

/// A request's images as Draw Things tensors, converted once for every image in
/// the batch.
nonisolated struct DrawThingsInputs: Sendable {
    /// At the output size.
    var startingImage: Data?
    /// In the order the user added them.
    var referenceImages: [Data] = []
}

nonisolated extension DrawThingsInputs {
    init(request: GenerationRequest) throws {
        func tensor(_ data: Data) throws -> Data {
            guard let image = CGImage.fromData(data) else {
                throw DrawThingsError.message("Mochi couldn't read an input image.")
            }
            // Draw Things reads a fourth channel as transparency to fill in.
            return try ImageHelpers.imageToDTTensor(image, forceRGB: true)
        }
        try self.init(
            startingImage: request.startingImageData.map(tensor),
            referenceImages: request.inputImageData.map(tensor))
    }
}

nonisolated protocol DrawThingsTransport: Sendable {
    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
    /// - Parameter showsPreview: whether to decode the previews Draw Things sends
    ///   and emit them to `session`.
    func generate(
        payload: DrawThingsPayload, inputs: DrawThingsInputs, prompt: String, seed: UInt32,
        sharedSecret: String?, showsPreview: Bool, session: GenerationSession
    ) async throws -> CGImage?
}

/// Uses the package's public protobuf messages with gRPC's calls directly: the
/// package's generated client is internal, and its higher-level service keeps a
/// connection open, fetches its own catalog and echoes before every generation.
actor GRPCDrawThingsTransport: DrawThingsTransport {
    private static let echo = MethodDescriptor(
        fullyQualifiedService: "ImageGenerationService", method: "Echo")
    private static let generateImage = MethodDescriptor(
        fullyQualifiedService: "ImageGenerationService", method: "GenerateImage")

    /// One connection per call: Mochi holds none between them.
    private static func transport(for connection: DrawThingsConnection) throws
        -> HTTP2ClientTransport.Posix
    {
        let security: HTTP2ClientTransport.Posix.TransportSecurity
        if connection.useTLS {
            // Draw Things uses a self-signed server certificate, so TLS encrypts the
            // connection but does not authenticate the host. Settings says so.
            security = .tls { $0.serverCertificateVerification = .noVerification }
        } else {
            security = .plaintext
        }
        // A host name's target would send an IPv4 address as the TLS server name,
        // which TLS forbids.
        var address = in_addr()
        let target: any ResolvableTarget =
            inet_pton(AF_INET, connection.host, &address) == 1
            ? .ipv4(address: connection.host, port: connection.port)
            : IPv4FirstHost(host: connection.host, port: connection.port)
        var resolvers = NameResolverRegistry.defaults
        resolvers.registerFactory(IPv4FirstHost.Factory())
        return try HTTP2ClientTransport.Posix(
            target: target, transportSecurity: security,
            config: .defaults {
                // Draw Things compresses large responses.
                $0.compression.enabledAlgorithms = .all
            },
            resolverRegistry: resolvers)
    }

    private static func options(seconds: Int64) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(seconds)
        // Requests carry uncompressed input tensors.
        options.maxRequestMessageBytes = 256 * 1024 * 1024
        options.maxResponseMessageBytes = 64 * 1024 * 1024
        return options
    }

    /// Makes one call on its own connection. A call whose stream never opened throws
    /// `DrawThingsUnopenedCall`, so it can be made again safely.
    private static func call<Result: Sendable>(
        _ connection: DrawThingsConnection,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (GRPCClient<HTTP2ClientTransport.Posix>, StreamOpening) async throws -> Result
    ) async throws -> Result {
        let opening = StreamOpening()
        do {
            return try await withGRPCClient(transport: transport(for: connection)) { client in
                try await body(client, opening)
            }
        } catch let error as RPCError
            where !opening.isOpen && [.unavailable, .deadlineExceeded].contains(error.code)
        {
            throw DrawThingsUnopenedCall(error: error)
        }
    }

    /// How many times a call is made when its connection never opens. A server Mac
    /// that is asleep wakes on the first attempt but may not answer within its wait.
    static let connectionAttempts = 3

    /// The zero-based progress for a sampling signpost. Draw Things sends one more
    /// signpost, with `step` equal to `steps`, once sampling has finished.
    static func progress(samplingStep: Int32, steps: Int32) -> GenerationState.Progress? {
        guard steps > 0 else { return nil }
        let stepCount = Int(steps)
        return GenerationState.Progress(
            step: max(0, min(Int(samplingStep), stepCount - 1)), stepCount: stepCount)
    }

    /// Runs `operation` again, up to `attempts` times in all, while it fails
    /// because the connection never opened. Any other error, including a
    /// connection that closed during the call, is thrown at once: by then the
    /// server may already be working on the request.
    static func retryingUnopenedConnection<T>(
        attempts: Int = connectionAttempts,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard attempt < attempts, DrawThingsError.isConnectionFailure(error) else {
                    throw error
                }
                attempt += 1
            }
        }
    }

    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
    {
        try await Self.retryingUnopenedConnection {
            try await catalogAttempt(connection: connection, sharedSecret: sharedSecret)
        }
    }

    private func catalogAttempt(connection: DrawThingsConnection, sharedSecret: String?)
        async throws -> DrawThingsCatalog
    {
        var request = EchoRequest()
        request.name = "Mochi Diffusion"
        if let sharedSecret { request.sharedSecret = sharedSecret }
        let reply = try await Self.call(connection) { client, opening in
            try await client.unary(
                request: ClientRequest(message: request), descriptor: Self.echo,
                serializer: ProtobufSerializer<EchoRequest>(),
                deserializer: ProtobufDeserializer<EchoReply>(),
                options: Self.options(seconds: 10)
            ) { response in
                opening.open()
                return try response.message
            }
        }
        // Draw Things gives the same answer for a missing secret and a wrong one.
        if reply.sharedSecretMissing {
            throw DrawThingsError.message(
                sharedSecret?.isEmpty == false
                    ? "Draw Things didn't accept the shared secret."
                    : "Draw Things requires a shared secret.")
        }
        return DrawThingsCatalog(models: reply.override.models, loras: reply.override.loras)
    }

    func generate(
        payload: DrawThingsPayload, inputs: DrawThingsInputs, prompt: String, seed: UInt32,
        sharedSecret: String?, showsPreview: Bool, session: GenerationSession
    ) async throws -> CGImage? {
        // Only a call whose stream never opened is made again, so a generation that
        // has started is never sent twice.
        try await Self.retryingUnopenedConnection {
            try await generateAttempt(
                payload: payload, inputs: inputs, prompt: prompt, seed: seed,
                sharedSecret: sharedSecret, showsPreview: showsPreview, session: session)
        }
    }

    private func generateAttempt(
        payload: DrawThingsPayload, inputs: DrawThingsInputs, prompt: String, seed: UInt32,
        sharedSecret: String?, showsPreview: Bool, session: GenerationSession
    ) async throws -> CGImage? {
        try Task.checkCancellation()
        var configuration = payload.configuration
        configuration.seed = seed
        var request = ImageGenerationRequest()
        request.user = "Mochi Diffusion"
        request.device = .laptop
        request.scaleFactor = 1
        request.prompt = prompt
        request.negativePrompt = payload.negativePrompt
        request.configuration = try configuration.toFlatBufferData()
        request.override.models = payload.specification
        request.override.loras = payload.loraSpecifications
        Self.attach(inputs, to: &request)
        request.chunked = true
        if let sharedSecret { request.sharedSecret = sharedSecret }
        let steps = configuration.steps
        let previewFamily = payload.previewFamily
        let tensor = try await Self.call(payload.connection) { client, opening in
            try await client.serverStreaming(
                request: ClientRequest(message: request), descriptor: Self.generateImage,
                serializer: ProtobufSerializer<ImageGenerationRequest>(),
                deserializer: ProtobufDeserializer<ImageGenerationResponse>(),
                options: Self.options(seconds: 1800)
            ) { response in
                opening.open()
                var accumulator = DrawThingsImageAccumulator()
                for try await response in response.messages {
                    try Task.checkCancellation()
                    // Draw Things sends previews unasked. One that cannot be decoded is
                    // skipped: it is not part of the result.
                    if showsPreview, response.hasPreviewImage,
                        let preview = try? await Self.decode(
                            response.previewImage, family: previewFamily)
                    {
                        session.emit(.preview(preview))
                    }
                    if response.hasCurrentSignpost,
                        case .sampling(let sampling) = response.currentSignpost.signpost
                    {
                        if let progress = Self.progress(samplingStep: sampling.step, steps: steps) {
                            session.emit(.progress(progress))
                        }
                    } else {
                        session.emit(.state(.loading("Generating with Draw Things…")))
                    }
                    try accumulator.append(
                        response.generatedImages, isLastChunk: response.chunkState == .lastChunk)
                }
                return try accumulator.finishedImage()
            }
        }
        try Task.checkCancellation()
        return try await Self.decode(tensor)
    }

    /// The starting image goes in the request's content store, named by its
    /// SHA-256 as the protocol describes. References are moodboard (`shuffle`)
    /// hints, which Draw Things keeps in order; Mochi offers no per-image weight.
    nonisolated static func attach(
        _ inputs: DrawThingsInputs, to request: inout ImageGenerationRequest
    ) {
        if let image = inputs.startingImage {
            request.image = Data(SHA256.hash(data: image))
            request.contents = [image]
        }
        guard !inputs.referenceImages.isEmpty else { return }
        var hint = HintProto()
        hint.hintType = HintType.shuffle.rawValue
        hint.tensors = inputs.referenceImages.map { image in
            var tensor = TensorAndWeight()
            tensor.tensor = image
            tensor.weight = 1
            return tensor
        }
        request.hints = [hint]
    }

    /// - Parameter family: needed for a preview, whose latents are decoded with the
    ///   model family's colour coefficients; a finished image is already RGB.
    @MainActor
    private static func decode(_ tensor: Data, family: ModelFamily? = nil) throws
        -> CGImage
    {
        guard
            let image = try ImageHelpers.dtTensorToImage(tensor, modelFamily: family)
                .cgImageRepresentation
        else {
            throw GenerationError.malformedResponse
        }
        return image
    }
}

/// A host name whose IPv4 addresses are tried before its IPv6 ones. gRPC tries a
/// host's addresses one at a time, and a Draw Things server may listen on IPv4
/// only: a `.local` name that resolves to IPv6 addresses first would otherwise
/// spend the call's deadline on addresses that never answer.
nonisolated struct IPv4FirstHost: ResolvableTarget, Sendable {
    var host: String
    var port: Int

    struct Factory: NameResolverFactory, Sendable {
        func resolver(for target: IPv4FirstHost) -> NameResolver {
            let dns = NameResolvers.DNS().resolver(
                for: .dns(host: target.host, port: target.port))
            let names = dns.names.map { @Sendable result in
                var result = result
                for index in result.endpoints.indices {
                    let addresses = result.endpoints[index].addresses
                    result.endpoints[index].addresses =
                        addresses.filter { $0.ipv4 != nil } + addresses.filter { $0.ipv4 == nil }
                }
                return result
            }
            return NameResolver(
                names: RPCAsyncSequence(wrapping: names), updateMode: dns.updateMode,
                authority: dns.authority)
        }
    }
}

/// Whether a call's stream has opened: the server has the request once it has.
nonisolated final class StreamOpening: Sendable {
    private let opened = Mutex(false)

    var isOpen: Bool { opened.withLock { $0 } }

    func open() { opened.withLock { $0 = true } }
}

/// Final images only: a preview must never turn a truncated/failed stream into success.
nonisolated struct DrawThingsImageAccumulator {
    private var pending = Data()
    private var image: Data?
    static let byteLimit = 128 * 1024 * 1024

    mutating func append(_ chunks: [Data], isLastChunk: Bool) throws {
        let moreThanOneImageError = DrawThingsError.message(
            "Draw Things returned more than one image for a single-image request.")
        guard !chunks.isEmpty else { return }
        guard image == nil else {
            throw moreThanOneImageError
        }
        for chunk in chunks {
            guard chunk.count <= Self.byteLimit - pending.count else {
                throw DrawThingsError.message(
                    "Draw Things returned an image larger than Mochi's 128 MB limit.")
            }
            pending.append(chunk)
        }
        if isLastChunk {
            guard chunks.count == 1 else {
                throw moreThanOneImageError
            }
            image = pending
            pending = Data()
        }
    }

    func finishedImage() throws -> Data {
        guard pending.isEmpty, let image, !image.isEmpty else {
            throw DrawThingsError.message("Draw Things stopped before sending a complete image.")
        }
        return image
    }
}
