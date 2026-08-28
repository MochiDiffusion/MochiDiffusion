//
//  OpenAIRuntimeTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the parts of the hosted runtime that do not need a network: how a
/// server-sent event is read, how a failed response is classified, and one run
/// end to end against canned lines.
struct OpenAIRuntimeTests {
    private let account = OpenAIImageEngine.secretAccount

    private func runtime(
        key: String? = "sk-test",
        session: any HTTPSession
    ) -> OpenAIEngineRuntime {
        OpenAIEngineRuntime(
            secrets: InMemorySecretStore(key.map { [account: $0] } ?? [:]),
            account: account,
            session: session
        )
    }

    private func request(
        numberOfImages: Int = 1,
        previews: Bool = false,
        quality: ImageQuality = .auto
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: OpenAIImageEngine.id, key: "gpt-image-2"),
            displayName: "gpt-image-2",
            metadataFields: OpenAIImageEngine.gptImage2.metadataFields,
            payload: OpenAIGenerationPayload(
                apiModel: "gpt-image-2",
                size: CGSize(width: 1_024, height: 1_024),
                quality: quality,
                wantsPreviews: previews
            ),
            prompt: "a cat",
            negativePrompt: "",
            size: CGSize(width: 1_024, height: 1_024),
            startingImageData: nil,
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: nil,
            stepCount: nil,
            guidanceScale: nil,
            scheduler: nil,
            quality: quality == .auto ? nil : quality,
            mlComputeUnit: nil,
            useDenoisedIntermediates: previews,
            seed: 7,
            numberOfImages: numberOfImages,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
        )
    }

    private func partial(index: Int) -> String {
        "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":\(index),"
            + "\"b64_json\":\"\(base64PNG())\"}"
    }

    private var completed: String {
        "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"\(base64PNG())\"}"
    }

    /// Collects a session's events without racing the run that produces them.
    private func collect(
        _ session: GenerationSession,
        while body: @escaping @Sendable () async throws -> Void
    ) async throws -> [GenerationEvent] {
        let draining = Task { () -> [GenerationEvent] in
            var seen: [GenerationEvent] = []
            for await event in session.events { seen.append(event) }
            return seen
        }
        try await body()
        session.close()
        return await draining.value
    }

    // MARK: - Event parsing

    @Test("A partial-image event yields its index and a decodable image")
    func parsesPartialImage() throws {
        let event = try #require(OpenAIEngineRuntime.event(from: partial(index: 2)))

        #expect(event.type == "image_generation.partial_image")
        #expect(event.partialIndex == 2)
        #expect(event.image != nil)
    }

    @Test("A completed event yields the final image")
    func parsesCompleted() throws {
        let event = try #require(OpenAIEngineRuntime.event(from: completed))

        #expect(event.type == "image_generation.completed")
        #expect(event.partialIndex == nil)
        #expect(event.image != nil)
    }

    /// Everything a server-sent-event body contains besides data lines. Ignoring
    /// them rather than failing on them is what keeps the parser working when the
    /// service adds a field or a comment.
    @Test(
        "Non-data lines are ignored rather than failing the stream",
        arguments: [
            "",
            ": keep-alive comment",
            "event: image_generation.partial_image",
            "data: [DONE]",
            "data: ",
            "data: not json at all",
            "data: {\"no_type\":true}",
            "id: 42",
        ]
    )
    func ignoresNonDataLines(line: String) {
        #expect(OpenAIEngineRuntime.event(from: line) == nil)
    }

    @Test("An unknown event type parses without an image and is skipped downstream")
    func parsesUnknownType() throws {
        let event = try #require(
            OpenAIEngineRuntime.event(from: "data: {\"type\":\"image_generation.queued\"}"))

        #expect(event.type == "image_generation.queued")
        #expect(event.image == nil)
    }

    // MARK: - Error classification

    private func classify(_ status: Int, body: String = "") async -> any Error {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/images/generations")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            if !body.isEmpty { continuation.yield(body) }
            continuation.finish()
        }
        return await OpenAIEngineRuntime.error(for: response, lines: lines)
    }

    @Test("Authentication failures are named as such", arguments: [401, 403])
    func classifiesAuthFailure(status: Int) async {
        #expect(await classify(status) as? GenerationError == .authenticationFailed)
    }

    @Test("Being asked to slow down is not a fatal error")
    func classifiesRateLimit() async {
        #expect(await classify(429) as? GenerationError == .rateLimited)
    }

    /// The distinction D5 is about: the call succeeded and the service declined,
    /// so this must not read as a malfunction.
    @Test(
        "A content-policy decline is a refusal, carrying what the service said",
        arguments: [
            "moderation_blocked", "content_policy_violation", "safety_system_triggered",
        ]
    )
    func classifiesRefusal(code: String) async {
        let body = "{\"error\":{\"code\":\"\(code)\",\"message\":\"Your prompt was rejected.\"}}"

        #expect(
            await classify(400, body: body) as? GenerationError
                == .refused("Your prompt was rejected."))
    }

    /// The refusal codes are not verified against the live API, so an
    /// unrecognised 400 must still be reported usefully rather than swallowed.
    @Test("An unrecognised failure reports the service's own message")
    func classifiesUnknownFailure() async {
        let body = "{\"error\":{\"code\":\"something_new\",\"message\":\"Bad size.\"}}"

        #expect(await classify(400, body: body) as? GenerationError == .serviceFailure("Bad size."))
    }

    @Test("A failure with no readable body still names the status")
    func classifiesEmptyBody() async {
        let error = await classify(500) as? GenerationError

        #expect(error == .serviceFailure("The service returned 500."))
    }

    // MARK: - Running

    @Test("A missing key fails before anything is sent")
    func missingKeyFailsFast() async throws {
        let session = FakeHTTPSession(body: [completed])
        let runtime = runtime(key: nil, session: session)

        await #expect(throws: GenerationError.authenticationFailed) {
            try await runtime.run(
                request: request(),
                session: GenerationSession(requestID: UUID()),
                onResult: { _ in }
            )
        }
        #expect(session.lastRequest == nil)
    }

    @Test("The request body says what was decided, and nothing else")
    func requestBodyMatchesThePlan() async throws {
        let http = FakeHTTPSession(body: [completed])
        let generationSession = GenerationSession(requestID: UUID())

        try await runtime(session: http).run(
            request: request(previews: true, quality: .high),
            session: generationSession,
            onResult: { _ in }
        )

        let body = try #require(http.lastRequestBody)
        #expect(body["model"] as? String == "gpt-image-2")
        #expect(body["prompt"] as? String == "a cat")
        #expect(body["size"] as? String == "1024x1024")
        #expect(body["output_format"] as? String == "png")
        // One image per call, so the loop count never becomes the API's `n` (D6).
        #expect(body["n"] as? Int == 1)
        #expect(body["stream"] as? Bool == true)
        #expect(body["partial_images"] as? Int == 3)
        #expect(body["quality"] as? String == "high")
        // The credential goes in a header, never the body.
        #expect(!body.keys.contains("api_key"))
        let authorization = http.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "Bearer sk-test")
    }

    /// `auto` is the service's own default, so sending it says nothing.
    @Test("Auto quality is omitted rather than sent")
    func autoQualityIsOmitted() async throws {
        let http = FakeHTTPSession(body: [completed])

        try await runtime(session: http).run(
            request: request(quality: .auto),
            session: GenerationSession(requestID: UUID()),
            onResult: { _ in }
        )

        #expect(http.lastRequestBody?["quality"] == nil)
    }

    @Test("Previews off asks for no partial images")
    func previewsOffAsksForNone() async throws {
        let http = FakeHTTPSession(body: [completed])

        try await runtime(session: http).run(
            request: request(previews: false),
            session: GenerationSession(requestID: UUID()),
            onResult: { _ in }
        )

        #expect(http.lastRequestBody?["partial_images"] as? Int == 0)
    }

    /// The end-to-end path: partial images become previews and measured progress,
    /// and the completed image becomes a saved result.
    @Test("Partial images become previews and progress; the last becomes the result")
    func streamProducesPreviewsAndAResult() async throws {
        let http = FakeHTTPSession(
            body: [partial(index: 0), partial(index: 1), completed, "data: [DONE]"])
        let generationSession = GenerationSession(requestID: UUID())
        let results = ResultCollector()
        let runtime = runtime(session: http)
        let req = request(previews: true)

        let events = try await collect(generationSession) {
            try await runtime.run(
                request: req,
                session: generationSession,
                onResult: { await results.add($0) }
            )
        }

        let previews = events.compactMap { event -> CGImage? in
            if case .preview(let image) = event { return image }
            return nil
        }
        let progress = events.compactMap { event -> GenerationState.Progress? in
            if case .progress(let value) = event { return value }
            return nil
        }
        #expect(previews.count == 2)
        // Measured, not invented: the index comes from the service and the total
        // is what we asked for.
        #expect(progress.map(\.step) == [0, 1])
        #expect(progress.allSatisfy { $0.stepCount == 3 })

        let saved = await results.all
        #expect(saved.count == 1)
        #expect(saved[0].metadata.model == "gpt-image-2")
        #expect(saved[0].metadata.engine == "openai")
        #expect(saved[0].metadata.modelKey == "gpt-image-2")
        #expect(!saved[0].imageData.isEmpty)
    }

    /// Previews off means no preview events even when the service sends partials.
    @Test("With previews off, partial images are dropped")
    func previewsOffDropsPartials() async throws {
        let http = FakeHTTPSession(body: [partial(index: 0), completed])
        let generationSession = GenerationSession(requestID: UUID())
        let runtime = runtime(session: http)
        let req = request(previews: false)

        let events = try await collect(generationSession) {
            try await runtime.run(
                request: req, session: generationSession, onResult: { _ in })
        }

        #expect(!events.contains { if case .preview = $0 { return true } else { return false } })
    }

    @Test("A stream that never completes is reported as a shape we do not understand")
    func missingCompletedEventFails() async throws {
        let http = FakeHTTPSession(body: [partial(index: 0), "data: [DONE]"])

        await #expect(throws: GenerationError.malformedResponse) {
            try await runtime(session: http).run(
                request: request(previews: true),
                session: GenerationSession(requestID: UUID()),
                onResult: { _ in }
            )
        }
    }

    /// D6's reason for one call per image: cancelling after the second of five
    /// should cost two images, not five.
    @Test("Each image is a separate request")
    func oneRequestPerImage() async throws {
        let http = CountingHTTPSession(body: [completed])
        let results = ResultCollector()

        try await OpenAIEngineRuntime(
            secrets: InMemorySecretStore([account: "sk-test"]),
            account: account,
            session: http
        ).run(
            request: request(numberOfImages: 3),
            session: GenerationSession(requestID: UUID()),
            onResult: { await results.add($0) }
        )

        #expect(await http.count == 3)
        #expect(await results.all.count == 3)
    }

    @Test("A cancelled session stops before the next image")
    func cancellationStopsBetweenImages() async throws {
        let http = CountingHTTPSession(body: [completed])
        let generationSession = GenerationSession(requestID: UUID())
        let results = ResultCollector()

        try await OpenAIEngineRuntime(
            secrets: InMemorySecretStore([account: "sk-test"]),
            account: account,
            session: http
        ).run(
            request: request(numberOfImages: 5),
            session: generationSession,
            onResult: { result in
                await results.add(result)
                // Cancelled while the first image is being delivered.
                generationSession.cancel()
            }
        )

        #expect(await results.all.count == 1)
        #expect(await http.count == 1)
    }

    // MARK: - Interrupting a suspended request

    /// The P1 this suite missed. A network call suspends — on response headers,
    /// then on the next line — so polling `isCancelled` never runs, and neither a
    /// user cancelling nor the watchdog expiring would be noticed. The request
    /// would hold the serial queue for good and keep a billable call open.
    @Test(
        "Cancelling interrupts a request suspended on the network",
        .timeLimit(.minutes(1)),
        arguments: [HangingHTTPSession.Mode.beforeHeaders, .afterHeaders]
    )
    func cancelInterruptsASuspendedRequest(mode: HangingHTTPSession.Mode) async throws {
        let http = HangingHTTPSession(mode: mode)
        let generationSession = GenerationSession(requestID: UUID())
        let runtime = runtime(session: http)
        let req = request(previews: true)
        let results = ResultCollector()

        let run = Task {
            try await runtime.run(
                request: req,
                session: generationSession,
                onResult: { await results.add($0) }
            )
        }
        await http.waitUntilAsked()

        generationSession.cancel()

        // Returns rather than hanging. Without the fix this awaits until the
        // suite's time limit kills it.
        try await run.value
        #expect(await results.all.isEmpty)
        // Reaching the network, not just unblocking the caller: a cancelled
        // request that leaves the transfer running is still being paid for.
        if case .afterHeaders = mode {
            #expect(http.wasTerminated)
        }
    }

    /// Expiry has to interrupt for the same reason, and by the same route — the
    /// watchdog calls `expire()`, which runs the handlers `cancel()` does.
    @Test("Expiry interrupts a request suspended on the network", .timeLimit(.minutes(1)))
    func expiryInterruptsASuspendedRequest() async throws {
        let http = HangingHTTPSession(mode: .afterHeaders)
        let generationSession = GenerationSession(requestID: UUID())
        let runtime = runtime(session: http)
        let req = request(previews: true)

        let run = Task {
            try await runtime.run(
                request: req, session: generationSession, onResult: { _ in })
        }
        await http.waitUntilAsked()

        generationSession.expire()

        try await run.value
        #expect(generationSession.stopReason == .expired)
        #expect(http.wasTerminated)
    }

    /// A cancel arriving between images must not be lost. `TaskHandle` cancels a
    /// task it adopts after the fact, so the next image is stopped rather than
    /// started.
    @Test("A cancel arriving before the next image still stops it")
    func cancelBeforeAdoptionIsNotLost() async throws {
        let handle = TaskHandle()
        handle.cancel()

        let task = Task { () throws -> CGImage? in
            try await Task.sleep(for: .seconds(3_600))
            return nil
        }
        handle.adopt(task)

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Timeout policy

    /// The other P1. With no partial images there are no intermediate events, so a
    /// 60-second *idle* bound silently becomes a 60-second *total* one and kills a
    /// slow-but-healthy generation, discarding the image it was about to return.
    @Test("The bound is idle when there is a heartbeat and total when there is not")
    func timeoutPolicyDependsOnTheRequest() {
        let runtime = runtime(session: FakeHTTPSession())

        let streaming = runtime.idleTimeout(for: request(previews: true))
        let notStreaming = runtime.idleTimeout(for: request(previews: false))

        #expect(streaming == OpenAIEngineRuntime.streamingIdleTimeout)
        #expect(notStreaming == OpenAIEngineRuntime.nonStreamingTotalTimeout)
        // The distinction only helps if the no-heartbeat budget is the larger one.
        #expect(notStreaming! > streaming!)
    }

    /// §13.1 asks the UI not to imply a cancel is free when it is not.
    @Test("A hosted runtime says its work may still be billed; a local one does not")
    func billingHonesty() {
        #expect(runtime(session: FakeHTTPSession()).cancellationMayLeaveWorkBilled)
        #expect(!CoreMLEngineRuntime().cancellationMayLeaveWorkBilled)
        #expect(!IrisEngineRuntime().cancellationMayLeaveWorkBilled)
    }

    @Test("A foreign payload gets no timeout rather than a wrong one")
    func timeoutIsNilForAForeignPayload() {
        let foreign = GenerationRequest(
            modelID: ModelID(engine: .iris, key: "klein"),
            displayName: "klein",
            metadataFields: [.prompt],
            payload: IrisGenerationPayload(
                modelDirectory: "/models/klein", stepCount: 4, scheduler: .discreteFlowScheduler),
            prompt: "a cat",
            negativePrompt: "",
            size: CGSize(width: 64, height: 64),
            startingImageData: nil,
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: nil,
            stepCount: 4,
            guidanceScale: nil,
            scheduler: .discreteFlowScheduler,
            quality: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 1,
            numberOfImages: 1,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
        )

        #expect(runtime(session: FakeHTTPSession()).idleTimeout(for: foreign) == nil)
    }

    // MARK: - Helpers

    actor ResultCollector {
        private(set) var all: [GenerationResult] = []
        func add(_ result: GenerationResult) { all.append(result) }
    }

    /// Counts requests, so "one call per image" is measured rather than assumed.
    actor CountingHTTPSession: HTTPSession {
        private(set) var count = 0
        private let body: [String]

        init(body: [String]) {
            self.body = body
        }

        func lines(
            for request: URLRequest
        ) async throws -> (
            response: HTTPURLResponse, lines: AsyncThrowingStream<String, any Error>
        ) {
            count += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let lines = body
            let stream = AsyncThrowingStream<String, any Error> { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
            return (response, stream)
        }
    }
}

/// A transport that never answers, in the two ways it can fail to: no response
/// headers, and headers followed by a stream that yields nothing.
///
/// The gap these cover is the one a cooperative fake hides. `StallingRuntime` in
/// `IdleTimeoutTests` polls `isCancelled` in a sleep loop, so it proved the queue
/// releases its drain on expiry while never showing whether a *real* runtime can
/// be interrupted at all — and the hosted one could not: it suspends on the
/// network, where polling never runs.
nonisolated final class HangingHTTPSession: HTTPSession, @unchecked Sendable {
    enum Mode: Sendable {
        /// Never returns response headers.
        case beforeHeaders
        /// Returns headers, then a stream that never yields and never finishes.
        case afterHeaders
    }

    private let lock = NSLock()
    private let mode: Mode
    private var asked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var terminated = false

    init(mode: Mode) {
        self.mode = mode
    }

    /// Whether the transfer was torn down — the signal that cancellation reached
    /// the network rather than merely unblocking the caller.
    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if asked {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func noteAsked() {
        lock.lock()
        asked = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume() }
    }

    private func noteTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    func lines(
        for request: URLRequest
    ) async throws -> (response: HTTPURLResponse, lines: AsyncThrowingStream<String, any Error>) {
        noteAsked()
        if case .beforeHeaders = mode {
            // Suspends until the task is cancelled, which is what a server that
            // accepts a connection and says nothing looks like.
            try await Task.sleep(for: .seconds(3_600))
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            // Deliberately holds the continuation and yields nothing.
            continuation.onTermination = { [weak self] _ in self?.noteTerminated() }
        }
        return (response, stream)
    }
}
