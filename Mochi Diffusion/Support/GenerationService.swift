//
//  GenerationService.swift
//  Mochi Diffusion
//

import CoreGraphics
import CoreML
import Foundation
import os

actor GenerationService {
    struct Snapshot: Sendable {
        var queue: [GenerationRequest]
        var current: GenerationRequest?
    }

    /// The gallery this queue numbers output against and publishes previews to.
    ///
    /// Storing a `@MainActor` type in an actor is sound — global-actor isolation
    /// makes it `Sendable`, and every use below still goes through `MainActor.run`.
    /// Injected so the suites that drive this queue can each have their own gallery:
    /// two separately serialized suites are serial within themselves but not against
    /// each other, which is how a shared singleton produces a flake that passes alone
    /// and fails in a full run.
    private let imageGallery: ImageGallery
    private var logger = Logger()
    private var queue: [GenerationRequest] = []
    private var current: GenerationRequest?
    private var cancelingCurrentID: GenerationRequest.ID?
    /// The running request's cancellation flag and event route. Held so
    /// `stopCurrentGeneration()` can cancel without calling into a runtime that
    /// is blocked inside a synchronous generate.
    private var currentSession: GenerationSession?
    /// Whether the running request's work may outlive a cancel. Recorded when the
    /// runtime is chosen, because `stopCurrentGeneration` has the request but not
    /// the runtime.
    private var currentRuntimeMayLeaveWorkBilled = false
    private var processingTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var resultContinuations: [UUID: AsyncStream<GenerationResult>.Continuation] = [:]
    /// One runtime per engine, made on first use and kept.
    ///
    /// Kept, so a loaded Core ML pipeline stays warm between requests. Made lazily,
    /// so an engine nobody generates with never allocates one.
    private var runtimes: [EngineID: any GenerationEngineRuntime] = [:]
    private var nextImageIndex = 1
    private var didEmitResultForCurrentRequest = false
    /// Whether a preview frame has been applied since the last result was emitted.
    ///
    /// Results and events travel on separate channels, since results need
    /// back-pressure and previews do not, so a buffered preview can be applied
    /// *after* the gallery has replaced the preview with the finished image.
    /// Teardown skips clearing when a result was emitted, on the assumption that
    /// the insert did it, and this is how it tells that case from a late frame that
    /// would otherwise survive into the next request.
    private var didApplyPreviewSinceResult = false
    private let imageRepository: ImageRepository
    private let modelRepository: ModelRepository
    private let engineRegistry: EngineRegistry

    init(
        imageRepository: ImageRepository = ImageRepository(),
        modelRepository: ModelRepository = ModelRepository(),
        engineRegistry: EngineRegistry = EngineRegistry(),
        imageGallery: ImageGallery
    ) {
        self.imageRepository = imageRepository
        self.modelRepository = modelRepository
        self.engineRegistry = engineRegistry
        self.imageGallery = imageGallery
    }

    /// Latest-state stream: only the newest snapshot matters, so a suspended UI
    /// cannot accumulate obsolete ones. `results()` below stays unbounded on
    /// purpose — a dropped result is a lost image.
    func updates() -> AsyncStream<Snapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func results() -> AsyncStream<GenerationResult> {
        AsyncStream { continuation in
            let id = UUID()
            resultContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeResultContinuation(id) }
            }
        }
    }

    func enqueue(_ request: GenerationRequest) async {
        // Checked here rather than where a generator unwraps the payload: by then
        // the request has been dequeued and published as current, and the queue
        // cannot take that back. A mismatch is a wiring bug, so it is reported as
        // an internal failure naming the engine, not as something to reconfigure.
        guard let engine = engineRegistry.engine(request.modelID.engine) else {
            logger.error("no engine registered for \(request.modelID.description)")
            await updateStatus(.error("There is no engine for \(request.displayName)."))
            return
        }
        guard engine.accepts(payload: request.payload) else {
            logger.error(
                """
                \(request.modelID.engine.rawValue) was handed a payload it does not own \
                for \(request.modelID.description)
                """
            )
            await updateStatus(.error("There was a problem preparing \(request.displayName)."))
            return
        }

        queue.append(request)
        broadcastSnapshot()
        startProcessingIfNeeded()
    }

    func removeQueued(id: GenerationRequest.ID) {
        guard current?.id != id else { return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            broadcastSnapshot()
        }
    }

    func stopCurrentGeneration() async {
        guard let current else { return }
        guard cancelingCurrentID != current.id else { return }

        cancelingCurrentID = current.id
        broadcastSnapshot()
        // Says so when it is true rather than implying a cancel is always free.
        // Stopping a hosted request stops us waiting; it does not necessarily stop
        // the service, and the image may still be charged for.
        await updateGenerationState(
            .canceling(
                currentRuntimeMayLeaveWorkBilled
                    ? "Stopping. \(current.displayName) may still finish and charge for this image."
                    : nil
            )
        )
        // Synchronous, and it does not touch the runtime: one blocked inside
        // `generateImages` or `iris_generate` could not accept a call.
        currentSession?.cancel()
    }

    func updateStatus(_ status: GenerationState.Status) async {
        await updateGenerationState(status)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { await processQueue() }
    }

    /// Drains the queue until it is empty.
    ///
    /// Must not gate on `GenerationState`: nothing outside this actor restores
    /// `.ready`, so a failure that left `.error` would strand every later request in
    /// a queue no drain would start. Queue readiness is not a UI status.
    ///
    /// A stale `.error` heals on its own, since the first thing a started request
    /// does is report `.loading`.
    private func processQueue() async {
        defer { processingTask = nil }

        // Outer loop because the drain ends with an `await`. A request enqueued
        // during that await sees `processingTask` still set and so schedules no
        // drain of its own, and without re-checking here this task would then
        // clear `processingTask` and leave it queued.
        while !queue.isEmpty {
            await drainQueue()

            current = nil
            cancelingCurrentID = nil
            currentSession = nil
            broadcastSnapshot()
            await NotificationController.shared.sendQueueEmptyNotification()
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            current = request
            didEmitResultForCurrentRequest = false
            broadcastSnapshot()

            // The registry answers which engine owns the request and the engine
            // makes its own runtime, so adding an engine does not mean editing the
            // queue.
            guard let engine = engineRegistry.engine(request.modelID.engine) else {
                logger.error("no engine registered for \(request.modelID.description)")
                await updateStatus(.error("There is no engine for \(request.displayName)."))
                await finishCurrentRequest(request.id, restoreReadyAfterCancel: false)
                continue
            }
            let runtime = runtime(for: engine)
            currentRuntimeMayLeaveWorkBilled = runtime.cancellationMayLeaveWorkBilled

            let session = GenerationSession(requestID: request.id)
            currentSession = session
            var restoreReadyAfterCancel = false
            do {
                let outputDirectory = try await imageRepository.ensureOutputDirectory(
                    imageDir: request.imageDir
                )
                nextImageIndex = await MainActor.run { imageGallery.images.endIndex + 1 }

                if isCancelRequested(for: request.id) {
                    restoreReadyAfterCancel = true
                    session.close()
                    await finishCurrentRequest(
                        request.id,
                        restoreReadyAfterCancel: restoreReadyAfterCancel
                    )
                    continue
                }

                // One task drains the session's events in order, for the whole
                // request, so two progress updates cannot be applied out of order.
                let forwarding = Task { [weak self] in
                    for await event in session.events {
                        await self?.apply(event, for: request.id)
                    }
                }
                // Not a `defer`: closing the stream and joining the drain has to
                // happen on both the success and failure paths, and `defer` cannot
                // await. The outcome is held and rethrown afterwards so the
                // existing per-error handling below still sees it.
                // Started here rather than at enqueue: the clock bounds the gap
                // between signs of life while running, and on a serial queue a
                // request can sit behind a long one for minutes.
                // Starting it earlier would expire a whole queue at once.
                session.noteActivity()
                let watchdog = runtime.idleTimeout(for: request).map {
                    Self.startIdleWatchdog(session: session, timeout: $0)
                }
                let outcome: Result<Void, any Error>
                do {
                    try await runtime.run(
                        request: request,
                        session: session,
                        onResult: { [weak self] result in
                            guard let self else { return }
                            // A result is a sign of life that is not an event, so
                            // a run producing one image a minute is working rather
                            // than stalled.
                            session.noteActivity()
                            let filenameWithoutExtension = await self.nextFilename(
                                for: result.metadata
                            )
                            guard
                                let path = await imageRepository.writeImage(
                                    filenameWithoutExtension: filenameWithoutExtension,
                                    imageData: result.imageData,
                                    imageDir: outputDirectory.path(percentEncoded: false),
                                    imageType: request.imageType
                                )
                            else {
                                throw GenerationError.imageDirectoryNoAccess
                            }
                            let savedResult = GenerationResult(
                                id: result.id,
                                metadata: result.metadata,
                                imageData: result.imageData,
                                imageURL: path,
                                requestID: request.id
                            )
                            await self.emitResultForCurrentRequest(savedResult)
                        }
                    )
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                watchdog?.cancel()
                // Finish the stream rather than cancelling the drain, so events
                // already emitted are still applied, then wait for the drain to
                // end. Past this point no event from this request can be in
                // flight, which is what lets the next request reuse the UI state.
                session.close()
                await forwarding.value
                // Checked before the runtime's own outcome. A runtime that notices
                // the stop returns normally, so without this an expiry would be
                // indistinguishable from success and the UI would go quietly
                // `.ready` having produced nothing.
                if session.stopReason == .expired {
                    throw GenerationError.requestExpired
                }
                try outcome.get()
                // The terminal state belongs here rather than to the runtime, so a
                // dropped event cannot leave the UI stuck mid-generation.
                if !isCancelRequested(for: request.id) {
                    await updateStatus(.ready(nil))
                }
                restoreReadyAfterCancel = true
            } catch GenerationError.refused(let reason) {
                // Reported through `.ready` rather than `.error`: the call
                // succeeded and the service declined, so this is news rather than
                // a malfunction (D5). Both render the same banner today, so the
                // difference is the register the message is written in and the
                // state the queue is left in, not the presentation.
                logger.info("\(request.displayName) declined the prompt: \(reason)")
                await updateStatus(.ready(reason))
            } catch GenerationError.authenticationFailed {
                logger.error("\(request.displayName) rejected the stored credential.")
                await updateStatus(
                    .error(
                        "Couldn't sign in to \(request.displayName). Check the API key in Settings."
                    )
                )
            } catch GenerationError.rateLimited {
                // Not a malfunction either: the service asked us to slow down, and
                // the next request may well succeed.
                logger.info("\(request.displayName) is rate limiting requests.")
                await updateStatus(
                    .ready("\(request.displayName) is rate limiting requests. Try again shortly.")
                )
            } catch GenerationError.serviceFailure(let message) {
                logger.error("\(request.displayName) failed: \(message)")
                await updateStatus(.error(message))
            } catch GenerationError.malformedResponse {
                logger.error("\(request.displayName) returned something unexpected.")
                await updateStatus(
                    .error("\(request.displayName) returned a response Mochi couldn't read.")
                )
            } catch GenerationError.requestExpired {
                logger.error("\(request.displayName) stopped responding; gave up waiting.")
                await updateStatus(
                    .error(
                        "Stopped waiting for \(request.displayName): no response for too "
                            + "long. A remote service may still finish and charge for this image."
                    )
                )
            } catch GenerationError.requestedModelNotFound {
                logger.error("Couldn't load \(request.displayName) because it doesn't exist.")
                await updateStatus(
                    .ready("Couldn't load \(request.displayName) because it doesn't exist."))
            } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
                logger.error("Couldn't access images folder at \(path)")
                await updateStatus(
                    .error("Couldn't access images folder at: \(path)")
                )
            } catch GenerationError.imageDirectoryNoAccess {
                logger.error("Couldn't save image to images folder.")
                await updateStatus(
                    .error("Couldn't save image to the images folder.")
                )
            } catch GenerationError.pipelineNotAvailable {
                logger.error("Pipeline is not available.")
                await updateStatus(
                    .ready("There was a problem loading pipeline."))
            } catch {
                logger.error("There was a problem generating images: \(error)")
                await updateStatus(
                    .error("There was a problem generating images: \(error)"))
            }

            await finishCurrentRequest(
                request.id,
                restoreReadyAfterCancel: restoreReadyAfterCancel
            )
        }
    }

    /// Expires `session` once it has been quiet for `timeout`.
    ///
    /// Sleeps for exactly the time remaining rather than polling: every wake-up
    /// either expires the session or learns a newer deadline from it, so a long
    /// generation that keeps reporting costs one wake-up per reported event
    /// rather than one per interval.
    ///
    /// `static`, and holds no reference to the queue, so a watchdog cannot keep
    /// the actor alive and needs no actor hop to read the clock — `idleDuration`
    /// is lock-guarded precisely so this can stay synchronous.
    private static func startIdleWatchdog(
        session: GenerationSession,
        timeout: Duration
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let idle = session.idleDuration
                guard idle < timeout else {
                    session.expire()
                    return
                }
                do {
                    try await Task.sleep(for: timeout - idle)
                } catch {
                    return
                }
            }
        }
    }

    private func updateGenerationState(_ status: GenerationState.Status) async {
        await MainActor.run {
            GenerationState.shared.state = status
        }
    }

    /// Applies one event from the running session.
    ///
    /// The single checkpoint an event from a finished or cancelled request is
    /// dropped at, instead of the same two guards repeated in three handlers.
    private func apply(_ event: GenerationEvent, for requestID: GenerationRequest.ID) async {
        switch event {
        case .state(let status):
            await handleGeneratorStateUpdate(status, for: requestID)
        case .progress(let progress):
            await handleGeneratorProgressUpdate(progress, for: requestID)
        case .preview(let image):
            await handleGeneratorPreviewUpdate(image, for: requestID)
        }
    }

    /// The runtime for `engine`, made on first use.
    private func runtime(for engine: AnyGenerationEngine) -> any GenerationEngineRuntime {
        if let existing = runtimes[engine.id] {
            return existing
        }
        let runtime = engine.makeRuntime()
        runtimes[engine.id] = runtime
        return runtime
    }

    private func handleGeneratorStateUpdate(
        _ status: GenerationState.Status,
        for requestID: GenerationRequest.ID
    ) async {
        guard current?.id == requestID else { return }
        guard !isCancelRequested(for: requestID) else { return }
        await updateGenerationState(status)
    }

    private func updateGenerationProgress(
        _ progress: GenerationState.Progress
    ) async {
        await MainActor.run {
            GenerationState.shared.state = .running(progress)
        }
    }

    private func handleGeneratorProgressUpdate(
        _ progress: GenerationState.Progress,
        for requestID: GenerationRequest.ID
    ) async {
        guard current?.id == requestID else { return }
        guard !isCancelRequested(for: requestID) else { return }
        await updateGenerationProgress(progress)
    }

    private func handleGeneratorPreviewUpdate(
        _ image: CGImage?,
        for requestID: GenerationRequest.ID
    ) async {
        guard let image else {
            // Keep the last preview frame visible until result insertion/teardown.
            if current?.id == requestID, !isCancelRequested(for: requestID) {
                return
            }
            guard current?.id == requestID || current == nil else { return }
            await clearCurrentGeneratingImage(owner: requestID)
            return
        }

        guard current?.id == requestID else { return }
        if isCancelRequested(for: requestID) {
            return
        }

        await setCurrentGeneratingImage(image, owner: requestID)
        didApplyPreviewSinceResult = true
    }

    private func nextFilename(for metadata: GenerationMetadata) async -> String {
        let count = nextImageIndex
        nextImageIndex += 1
        return filenameWithoutExtension(prompt: metadata.prompt, seed: metadata.seed, count: count)
    }

    private func filenameWithoutExtension(prompt: String, seed: UInt32, count: Int) -> String {
        guard !prompt.isEmpty else {
            return "\(count).\(seed)"
        }
        let trimmed = String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed).\(count).\(seed)"
    }

    private func snapshot() -> Snapshot {
        let visibleCurrent: GenerationRequest?
        if let current, isCancelRequested(for: current.id) {
            visibleCurrent = nil
        } else {
            visibleCurrent = current
        }
        return Snapshot(queue: queue, current: visibleCurrent)
    }

    private func broadcastSnapshot() {
        let snapshot = snapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emitResultForCurrentRequest(_ result: GenerationResult) {
        didEmitResultForCurrentRequest = true
        didApplyPreviewSinceResult = false
        for continuation in resultContinuations.values {
            continuation.yield(result)
        }
    }

    private func setCurrentGeneratingImage(
        _ image: CGImage,
        owner: GenerationRequest.ID
    ) async {
        await MainActor.run {
            imageGallery.setCurrentGenerating(image: image, owner: owner)
        }
    }

    /// Clears the preview if `owner` still owns it, so teardown for one request
    /// cannot erase a preview the next has already put up.
    private func clearCurrentGeneratingImage(owner: GenerationRequest.ID) async {
        await MainActor.run {
            imageGallery.clearCurrentGenerating(owner: owner)
        }
    }

    private func isCancelRequested(for requestID: GenerationRequest.ID) -> Bool {
        cancelingCurrentID == requestID
    }

    private func finishCurrentRequest(
        _ requestID: GenerationRequest.ID,
        restoreReadyAfterCancel: Bool
    ) async {
        let cancelRequested = isCancelRequested(for: requestID)
        // The third condition is the fix: a result was emitted, so the insert was
        // expected to replace the preview, but a frame arrived after it and is
        // still on screen. Clearing only in that case keeps the common path
        // unchanged — no blank flash between the last preview and the inserted
        // image, and no change to whether the insert animates.
        if cancelRequested || !didEmitResultForCurrentRequest || didApplyPreviewSinceResult {
            await clearCurrentGeneratingImage(owner: requestID)
        }

        if cancelRequested {
            cancelingCurrentID = nil
            if restoreReadyAfterCancel && queue.isEmpty {
                await updateGenerationState(.ready(nil))
            }
        }

        if current?.id == requestID {
            currentSession = nil
        }
        didEmitResultForCurrentRequest = false
        didApplyPreviewSinceResult = false
    }

    private func removeResultContinuation(_ id: UUID) {
        resultContinuations[id] = nil
    }

}
