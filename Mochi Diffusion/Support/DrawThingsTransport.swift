//
//  DrawThingsTransport.swift
//  Mochi Diffusion
//

import CoreGraphics
import DrawThingsClient
import Foundation
import GRPC
import NIO

extension DrawThingsError {
    /// Whether `error` means the server could not be reached, rather than that it
    /// answered with an error of its own.
    static func isUnreachable(_ error: any Error) -> Bool {
        let status = (error as? any GRPCStatusTransformable)?.makeGRPCStatus()
        return status?.code == .unavailable || status?.code == .deadlineExceeded
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
}

nonisolated protocol DrawThingsTransport: Sendable {
    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
    func generate(
        payload: DrawThingsPayload, prompt: String, seed: UInt32,
        sharedSecret: String?, session: GenerationSession
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

    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
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
            if reply.sharedSecretMissing {
                throw DrawThingsError.message(
                    "Draw Things requires a shared secret.")
            }
            return DrawThingsCatalog(models: reply.override.models)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    func generate(
        payload: DrawThingsPayload, prompt: String, seed: UInt32,
        sharedSecret: String?, session: GenerationSession
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

    @MainActor
    private static func decode(_ tensor: Data) throws -> CGImage {
        guard let image = try ImageHelpers.dtTensorToImage(tensor).cgImageRepresentation else {
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
            throw DrawThingsError.message("Draw Things ended the stream without a complete image.")
        }
        return image
    }
}
