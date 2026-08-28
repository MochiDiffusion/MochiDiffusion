//
//  OpenAIEngineRuntime.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import os

/// Runs a generation against the OpenAI image API.
///
/// Streams, and not only for previews. A non-streaming call produces no sign of
/// life until it returns, which would turn ``idleTimeout`` into exactly the
/// wall-clock budget D4 rejected. Partial images are what make an idle bound
/// meaningful, so streaming is load-bearing rather than a nicety.
nonisolated final class OpenAIEngineRuntime: GenerationEngineRuntime {
    private static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    /// The most the API accepts. Requested only when previews are on.
    private static let maxPartialImages = 3

    private let secrets: any SecretStore
    private let account: String
    private let session: any HTTPSession
    private let logger = Logger()

    init(secrets: any SecretStore, account: String, session: any HTTPSession) {
        self.secrets = secrets
        self.account = account
        self.session = session
    }

    /// Generous, because it bounds silence rather than duration: a high-quality
    /// 3840x2160 image can take minutes, but a stream that says nothing for a
    /// minute has stopped.
    var idleTimeout: Duration? { .seconds(60) }

    func run(
        request: GenerationRequest,
        session generationSession: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard let payload = request.payload as? OpenAIGenerationPayload else {
            throw EngineError.payloadDoesNotBelongToEngine(engine: OpenAIImageEngine.id)
        }
        // Read at run time, never carried in the payload: a payload is queued and
        // logged, and a credential belongs in neither.
        guard let apiKey = secrets.secret(for: account), !apiKey.isEmpty else {
            throw GenerationError.authenticationFailed
        }

        generationSession.emit(.state(.loading(nil)))

        // One request per image, per D6. Cancelling after the second of five
        // should cost two images rather than five, results reach the gallery as
        // they arrive, and partial-image previews are per-request.
        for index in 0..<request.numberOfImages {
            if generationSession.isCancelled { return }

            let image = try await generateOne(
                request: request,
                payload: payload,
                apiKey: apiKey,
                session: generationSession
            )
            guard let image else { return }
            if generationSession.isCancelled { return }

            let result = try await makeResult(
                image: image,
                request: request,
                payload: payload,
                index: index
            )
            try await onResult(result)
        }
    }

    // MARK: - One image

    /// Returns the finished image, or `nil` if the session stopped first.
    private func generateOne(
        request: GenerationRequest,
        payload: OpenAIGenerationPayload,
        apiKey: String,
        session generationSession: GenerationSession
    ) async throws -> CGImage? {
        let urlRequest = try makeURLRequest(request: request, payload: payload, apiKey: apiKey)
        let (response, lines) = try await session.lines(for: urlRequest)

        guard (200..<300).contains(response.statusCode) else {
            throw await Self.error(for: response, lines: lines)
        }

        let partialsRequested = payload.wantsPreviews ? Self.maxPartialImages : 0
        var finished: CGImage?

        for try await line in lines {
            if generationSession.isCancelled { return nil }
            guard let event = Self.event(from: line) else { continue }

            switch event.type {
            case "image_generation.partial_image":
                guard payload.wantsPreviews, let image = event.image else { continue }
                // `partial_image_index` carries no total, but we chose the total,
                // so this progress is measured rather than invented.
                generationSession.emit(
                    .progress(
                        GenerationState.Progress(
                            step: event.partialIndex ?? 0,
                            stepCount: partialsRequested
                        )
                    )
                )
                generationSession.emit(.preview(image))
            case "image_generation.completed":
                guard let image = event.image else { throw GenerationError.malformedResponse }
                finished = image
            case "error":
                throw GenerationError.serviceFailure(event.message ?? "Unknown error")
            default:
                continue
            }
        }

        guard let finished else {
            // The stream ended without a completed event. Not a refusal, which the
            // service states, and not a timeout, which the watchdog reports — so it
            // is a shape we do not understand.
            throw GenerationError.malformedResponse
        }
        return finished
    }

    private func makeURLRequest(
        request: GenerationRequest,
        payload: OpenAIGenerationPayload,
        apiKey: String
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "model": payload.apiModel,
            "prompt": request.prompt,
            "size": "\(Int(payload.size.width))x\(Int(payload.size.height))",
            // One image per call, per D6.
            "n": 1,
            // Always PNG. Lossless, and it is re-encoded anyway: Mochi embeds its
            // own metadata, which the service's bytes cannot carry, so the user's
            // chosen output type is applied on the way to disk (D7).
            "output_format": "png",
            "stream": true,
            "partial_images": payload.wantsPreviews ? Self.maxPartialImages : 0,
        ]
        // `auto` is the service's own default, so sending it says nothing. Omitted
        // rather than sent, to keep the request to what was actually chosen.
        if payload.quality != .auto {
            body["quality"] = payload.quality.rawValue
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    // MARK: - Results

    private func makeResult(
        image: CGImage,
        request: GenerationRequest,
        payload: OpenAIGenerationPayload,
        index: Int
    ) async throws -> GenerationResult {
        let metadata = GenerationMetadata(
            prompt: request.prompt,
            negativePrompt: "",
            width: image.width,
            height: image.height,
            model: payload.apiModel,
            engine: request.modelID.engine.rawValue,
            modelKey: request.modelID.key,
            quality: request.quality?.rawValue ?? "",
            startingImage: "",
            controlNetImage: "",
            inputImages: [],
            scheduler: .dpmSolverMultistepScheduler,
            mlComputeUnit: nil,
            seed: request.seed,
            steps: 0,
            guidanceScale: 0,
            generatedDate: Date(),
            metadataFields: request.metadataFields
        )

        // Re-encoded through the same path both local engines use, because that is
        // what embeds Mochi's metadata. `scheduler`, `steps` and `guidanceScale`
        // above are unread: this model declares none of them, so
        // `metadata(including:)` never writes them. They are the last places a
        // hosted engine still has to name a value it does not have, and section
        // 6.5 is what removes them.
        guard let data = await encode(image: image, metadata: metadata, request: request) else {
            throw GenerationError.malformedResponse
        }
        return GenerationResult(
            metadata: metadata,
            imageData: data,
            requestID: request.id
        )
    }

    @MainActor
    private func encode(
        image: CGImage,
        metadata: GenerationMetadata,
        request: GenerationRequest
    ) async -> Data? {
        var sdi = SDImage(image: image, aspectRatio: 0, path: "")
        sdi.prompt = metadata.prompt
        sdi.model = metadata.model
        sdi.engine = metadata.engine
        sdi.modelKey = metadata.modelKey
        sdi.quality = metadata.quality
        sdi.seed = metadata.seed
        sdi.generatedDate = metadata.generatedDate
        return await sdi.imageData(
            UTType.fromString(request.imageType),
            metadataFields: metadata.metadataFields
        )
    }

    // MARK: - Parsing

    /// One decoded server-sent event, reduced to the fields this runtime uses.
    struct StreamEvent {
        var type: String
        var partialIndex: Int?
        var image: CGImage?
        var message: String?
    }

    /// Decodes an SSE `data:` line, ignoring everything else — comments, `event:`
    /// lines, blank separators, and the `[DONE]` sentinel.
    static func event(from line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !json.isEmpty, json != "[DONE]" else { return nil }
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        var event = StreamEvent(type: type)
        event.partialIndex = object["partial_image_index"] as? Int
        if let encoded = object["b64_json"] as? String,
            let bytes = Data(base64Encoded: encoded)
        {
            event.image = CGImage.fromData(bytes)
        }
        if let error = object["error"] as? [String: Any] {
            event.message = error["message"] as? String
        }
        return event
    }

    /// Maps a failed response onto something the user can act on.
    ///
    /// The status code carries most of it. A refusal is distinguished by the
    /// error's own code, which is **not** verified against the live API — the
    /// documentation read for §13.2 does not enumerate error codes. Treated as a
    /// widening rather than a claim: an unrecognised 400 is reported as a service
    /// failure with the message the API supplied, which is honest and actionable
    /// either way.
    static func error(
        for response: HTTPURLResponse,
        lines: AsyncThrowingStream<String, any Error>
    ) async -> any Error {
        var body = ""
        // A failure body is small and not streamed, but it arrives on the same
        // channel. A read error here must not mask the status code, which is the
        // more useful signal, so it is swallowed rather than propagated.
        do {
            for try await line in lines {
                body += line
            }
        } catch {
            // Keep whatever arrived.
        }
        let parsed = errorFields(in: body)
        let message = parsed.message ?? "The service returned \(response.statusCode)."

        switch response.statusCode {
        case 401, 403:
            return GenerationError.authenticationFailed
        case 429:
            return GenerationError.rateLimited
        case 400 where isRefusal(parsed.code):
            return GenerationError.refused(message)
        default:
            return GenerationError.serviceFailure(message)
        }
    }

    private static func isRefusal(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return code.contains("moderation") || code.contains("content_policy")
            || code.contains("safety")
    }

    private static func errorFields(in body: String) -> (code: String?, message: String?) {
        guard
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (error["code"] as? String, error["message"] as? String)
    }
}
