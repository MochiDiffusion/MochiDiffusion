//
//  DrawThingsTransport.swift
//  Mochi Diffusion
//

import CoreGraphics
import CryptoKit
import DrawThingsClient
import Foundation
import GRPC
import NIO

extension DrawThingsError {
    /// Whether `error` means there is no connection to the server, rather than that
    /// it answered with an error of its own: Mochi could not connect, or the
    /// connection closed during a call.
    static func isUnreachable(_ error: any Error) -> Bool {
        isConnectionFailure(error)
            || (error as? any GRPCStatusTransformable)?.makeGRPCStatus().code == .unavailable
    }

    /// Mochi could not open a connection. The channel pool reports this, as
    /// `deadlineExceeded` once the call's deadline passes.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        error is GRPCConnectionPoolError
    }

    /// A failed generation's error, worded for the generation alert. Other errors,
    /// including Draw Things' own, keep their text.
    static func generationFailure(_ error: any Error, connection: DrawThingsConnection)
        -> any Error
    {
        guard let status = (error as? any GRPCStatusTransformable)?.makeGRPCStatus() else {
            return error
        }
        if isConnectionFailure(error) {
            return DrawThingsError.message(
                String(
                    localized: "Couldn't reach the Draw Things server at \(connection.serverName).",
                    comment: "Generation error when the Draw Things server cannot be reached"
                ))
        }
        if isUnreachable(error) {
            return DrawThingsError.connectionClosed(
                String(
                    localized:
                        "Draw Things closed the connection before the image was finished.",
                    comment: "Generation error when the connection closes during a generation"
                ))
        }
        let detail = status.message.flatMap { $0.isEmpty ? nil : $0 } ?? "\(status.code)"
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

/// Uses the package's public protobuf messages with gRPC's async calls. The package's
/// higher-level service doesn't expose an Echo deadline; a task-group timeout around
/// its uncancellable future would still wait for that child forever on scope exit.
actor GRPCDrawThingsTransport: DrawThingsTransport {
    nonisolated private struct Client: GRPCClient {
        var channel: any GRPCChannel
        var defaultCallOptions = CallOptions()
    }

    private func channel(for connection: DrawThingsConnection) throws -> any GRPCChannel {
        let security: GRPCChannelPool.Configuration.TransportSecurity
        if connection.useTLS {
            // Draw Things uses a self-signed server certificate, so TLS encrypts the
            // connection but does not authenticate the host. Settings says so.
            security = .tls(
                .makeClientConfigurationBackedByNIOSSL(certificateVerification: .none))
        } else {
            security = .plaintext
        }
        return try GRPCChannelPool.with(
            target: .host(connection.host, port: connection.port),
            transportSecurity: security,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton
        ) { configuration in
            configuration.maximumReceiveMessageLength = 64 * 1024 * 1024
        }
    }

    private func options(seconds: Int64) -> CallOptions {
        var options = CallOptions(timeLimit: .timeout(.seconds(seconds)))
        options.messageEncoding = .enabled(
            .init(
                forRequests: nil, decompressionLimit: .absolute(64 * 1024 * 1024)
            ))
        return options
    }

    /// How many times a call is made when its connection never opens. A server Mac
    /// that is asleep wakes on the first attempt but may not answer within its wait.
    static let connectionAttempts = 3

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
        let channel = try channel(for: connection)
        do {
            var request = EchoRequest()
            request.name = "Mochi Diffusion"
            if let sharedSecret { request.sharedSecret = sharedSecret }
            let reply: EchoReply = try await Client(channel: channel).performAsyncUnaryCall(
                path: "/ImageGenerationService/Echo", request: request,
                callOptions: options(seconds: 10)
            )
            try await channel.close().get()
            // Draw Things gives the same answer for a missing secret and a wrong one.
            if reply.sharedSecretMissing {
                throw DrawThingsError.message(
                    sharedSecret?.isEmpty == false
                        ? "Draw Things didn't accept the shared secret."
                        : "Draw Things requires a shared secret.")
            }
            return DrawThingsCatalog(models: reply.override.models, loras: reply.override.loras)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    func generate(
        payload: DrawThingsPayload, inputs: DrawThingsInputs, prompt: String, seed: UInt32,
        sharedSecret: String?, showsPreview: Bool, session: GenerationSession
    ) async throws -> CGImage? {
        // The pool fails a call before its stream opens, so a generation that has
        // started is never sent twice.
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
        let channel = try channel(for: payload.connection)
        do {
            var configuration = payload.configuration
            configuration.seed = Int64(seed)
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
            let stream: GRPCAsyncResponseStream<ImageGenerationResponse> = Client(channel: channel)
                .performAsyncServerStreamingCall(
                    path: "/ImageGenerationService/GenerateImage", request: request,
                    callOptions: options(seconds: 1800)
                )
            var accumulator = DrawThingsImageAccumulator()
            for try await response in stream {
                try Task.checkCancellation()
                // Draw Things sends previews unasked. One that cannot be decoded is
                // skipped: it is not part of the result.
                if showsPreview, response.hasPreviewImage,
                    let preview = try? await Self.decode(
                        response.previewImage, family: payload.previewFamily)
                {
                    session.emit(.preview(preview))
                }
                if response.hasCurrentSignpost,
                    case .sampling(let sampling) = response.currentSignpost.signpost
                {
                    session.emit(
                        .progress(
                            GenerationState.Progress(
                                step: Int(sampling.step), stepCount: Int(configuration.steps)
                            )))
                } else {
                    session.emit(.state(.loading("Generating with Draw Things…")))
                }
                try accumulator.append(
                    response.generatedImages, isLastChunk: response.chunkState == .lastChunk)
            }
            try await channel.close().get()
            try Task.checkCancellation()
            let tensor = try accumulator.finishedImage()
            return try await Self.decode(tensor)
        } catch {
            try? await channel.close().get()
            throw error
        }
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
    private static func decode(_ tensor: Data, family: LatentModelFamily? = nil) throws
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
