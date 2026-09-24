//
//  OpenAIEngineRuntime.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Runs a generation against the OpenAI image API.
///
/// Streams, and not only for previews: a non-streaming call gives no sign of life
/// until it returns, which would make `idleTimeout` a wall-clock budget rather than
/// an idle one. Partial images are the heartbeat that makes the bound meaningful.
nonisolated final class OpenAIEngineRuntime: GenerationEngineRuntime {
    private static let generationsEndpoint = URL(
        string: "https://api.openai.com/v1/images/generations"
    )!
    private static let editsEndpoint = URL(string: "https://api.openai.com/v1/images/edits")!
    /// The most the API accepts. Requested only when previews are on.
    private static let maxPartialImages = 3

    private let secrets: any SecretStore
    private let account: String
    private let session: any HTTPSession

    init(secrets: any SecretStore, account: String, session: any HTTPSession) {
        self.secrets = secrets
        self.account = account
        self.session = session
    }

    /// Bounds silence when there is a heartbeat to measure it against, and total
    /// duration when there is not.
    ///
    /// With partial images requested, every one is a sign of life, so a minute of
    /// silence means the stream has stopped even though a high-quality 3840x2160
    /// image can legitimately take minutes to finish.
    ///
    /// With `partial_images: 0` the only event is the final one, so nothing resets
    /// an idle clock and the same number would become a total budget, expiring a slow
    /// but healthy generation. That case gets an explicitly generous total budget.
    ///
    /// Partials are not requested purely as heartbeats: that would fetch images the
    /// user asked not to receive, and whether streamed partials affect billing is
    /// unconfirmed.
    static let streamingIdleTimeout = Duration.seconds(60)
    static let nonStreamingTotalTimeout = Duration.seconds(300)

    var cancellationMayLeaveWorkBilled: Bool { true }

    func idleTimeout(for request: GenerationRequest) -> Duration? {
        guard let payload = request.payload as? OpenAIGenerationPayload else { return nil }
        return payload.wantsPreviews
            ? Self.streamingIdleTimeout
            : Self.nonStreamingTotalTimeout
    }

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

        generationSession.emit(
            .state(
                .loading(
                    String(
                        localized: "Generating with OpenAI...",
                        comment: "Text displayed while waiting for OpenAI image generation"
                    )
                )
            )
        )

        // Registered once, cancelling whichever image is in flight.
        //
        // Polling `isCancelled` is not enough here: a network call can stay
        // suspended on response headers or the next stream line indefinitely. So
        // the work runs in a task the handler can cancel, which terminates the
        // stream and cancels the underlying transfer.
        let inFlight = TaskHandle()
        generationSession.onCancel { inFlight.cancel() }

        // One request per image: cancelling after the second of five costs two
        // rather than five, results reach the gallery as they arrive, and
        // partial-image previews are per-request.
        for index in 0..<request.numberOfImages {
            if generationSession.isCancelled { return }

            let image = try await generateOne(
                request: request,
                payload: payload,
                apiKey: apiKey,
                session: generationSession,
                inFlight: inFlight
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
        session generationSession: GenerationSession,
        inFlight: TaskHandle
    ) async throws -> CGImage? {
        let urlRequest = try makeURLRequest(request: request, payload: payload, apiKey: apiKey)

        // Both awaits below can suspend indefinitely, so both are inside the
        // cancellable task rather than only the loop.
        let work = Task { () throws -> CGImage? in
            try await self.stream(
                urlRequest: urlRequest,
                payload: payload,
                session: generationSession
            )
        }
        inFlight.adopt(work)
        do {
            return try await work.value
        } catch is CancellationError {
            // Stopped on purpose, by the user or the watchdog. The queue reads the
            // session's stop reason to tell which.
            return nil
        }
    }

    /// The suspending half, in its own function so the task above wraps all of it.
    private func stream(
        urlRequest: URLRequest,
        payload: OpenAIGenerationPayload,
        session generationSession: GenerationSession
    ) async throws -> CGImage? {
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
            case "image_generation.partial_image", "image_edit.partial_image":
                guard payload.wantsPreviews, let image = event.image else { continue }
                // `partial_image_index` carries no total, but we chose the total,
                // so this progress is measured rather than invented.
                generationSession.emit(
                    .progress(
                        GenerationState.Progress(
                            step: event.partialIndex ?? 0,
                            stepCount: partialsRequested,
                            kind: .preview
                        )
                    )
                )
                generationSession.emit(.preview(image))
            case "image_generation.completed", "image_edit.completed":
                guard let image = event.image else { throw GenerationError.malformedResponse }
                finished = image
            case "error":
                throw GenerationError.serviceFailure(event.message ?? "Unknown error")
            default:
                continue
            }
        }

        // Cancelling terminates the stream, so the loop above ends without a
        // completed event. That is a stop, not a malformed response, and reporting
        // it as the latter would turn every cancellation into an error.
        if generationSession.isCancelled { return nil }
        guard let finished else {
            // The stream ended without a completed event. Not a refusal, which the
            // service states, and not a stop, which is handled above — so it is a
            // shape we do not understand.
            throw GenerationError.malformedResponse
        }
        return finished
    }

    private func makeURLRequest(
        request: GenerationRequest,
        payload: OpenAIGenerationPayload,
        apiKey: String
    ) throws -> URLRequest {
        var fields: [String: Any] = [
            "model": payload.apiModel,
            "prompt": request.prompt,
            "size": "\(Int(payload.size.width))x\(Int(payload.size.height))",
            // One image per call; the loop above handles the count.
            "n": 1,
            // Always PNG: lossless, and re-encoded anyway, since Mochi embeds its
            // own metadata and applies the user's chosen output type on the way to
            // disk.
            "output_format": "png",
            "moderation": "low",
            "stream": true,
            "partial_images": payload.wantsPreviews ? Self.maxPartialImages : 0,
        ]
        // `auto` is the service's own default, so sending it says nothing. Omitted
        // rather than sent, to keep the request to what was actually chosen.
        if payload.quality != .auto {
            fields["quality"] = payload.quality.rawValue
        }

        var urlRequest = URLRequest(
            url: request.inputImageData.isEmpty ? Self.generationsEndpoint : Self.editsEndpoint
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        if request.inputImageData.isEmpty {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } else {
            let boundary = "MochiDiffusion-\(UUID().uuidString)"
            urlRequest.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            urlRequest.httpBody = Self.multipartBody(
                fields: fields,
                images: request.inputImageData,
                boundary: boundary
            )
        }
        return urlRequest
    }

    /// The edits endpoint takes repeated `image[]` parts. Filenames are transport
    /// labels only; source names are kept separately in request metadata because
    /// pasted images may have none and that list is not positionally aligned.
    private static func multipartBody(
        fields: [String: Any],
        images: [Data],
        boundary: String
    ) -> Data {
        var body = Data()

        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n", to: &body)
            append("\(value)\r\n", to: &body)
        }

        for (index, image) in images.enumerated() {
            append("--\(boundary)\r\n", to: &body)
            append(
                "Content-Disposition: form-data; name=\"image[]\"; "
                    + "filename=\"input-\(index + 1).png\"\r\n",
                to: &body
            )
            append("Content-Type: image/png\r\n\r\n", to: &body)
            body.append(image)
            append("\r\n", to: &body)
        }

        append("--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
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
            inputImages: request.inputImageNames.compactMap { $0 },
            scheduler: .dpmSolverMultistepScheduler,
            mlComputeUnit: nil,
            seed: request.seed,
            steps: 0,
            guidanceScale: 0,
            generatedDate: Date(),
            metadataFields: request.metadataFields
        )

        // Re-encoded through the same path the local engines use, because that is
        // what embeds Mochi's metadata. `scheduler`, `steps` and `guidanceScale`
        // above are placeholders: this model declares none of them, so
        // `metadata(including:)` never writes them.
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
        sdi.inputImages = metadata.inputImages
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
    /// The status code carries most of it. A refusal is distinguished by the error's
    /// own code, which is not verified against the live API, so an unrecognised 400
    /// is reported as a service failure carrying the message the API supplied.
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
            if isInsufficientQuota(code: parsed.code, type: parsed.type) {
                return GenerationError.insufficientQuota
            }
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

    private static func isInsufficientQuota(code: String?, type: String?) -> Bool {
        if let code = code?.lowercased() {
            return code == "credit_balance_exhausted" || code == "insufficient_quota"
                || code == "billing_hard_limit_reached"
        }
        return type?.lowercased() == "insufficient_quota"
    }

    /// Not private: ``OpenAICredentialCheck`` reports the same service's failures
    /// and there is one place the API's error envelope is understood.
    static func errorFields(in body: String) -> (code: String?, type: String?, message: String?) {
        guard
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return (nil, nil, nil)
        }
        return (
            error["code"] as? String,
            error["type"] as? String,
            error["message"] as? String
        )
    }
}

/// Holds whichever task is currently in flight, so one cancellation handler can
/// stop it whatever image the loop has reached.
///
/// Lock-guarded rather than an actor, and per-run rather than on the runtime: a
/// handler runs synchronously on whichever thread cancelled, and `makeRuntime()`
/// is called once per engine so runtime-level state would be shared across
/// requests.
nonisolated final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<CGImage?, any Error>?
    private var isCancelled = false

    /// Takes ownership of `task`, cancelling it immediately if a cancel already
    /// arrived — otherwise a cancel landing between images would be lost.
    func adopt(_ task: Task<CGImage?, any Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
