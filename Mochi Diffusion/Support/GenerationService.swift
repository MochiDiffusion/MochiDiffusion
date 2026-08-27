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

    static let shared = GenerationService()

    private var logger = Logger()
    private var queue: [GenerationRequest] = []
    private var current: GenerationRequest?
    private var cancelingCurrentID: GenerationRequest.ID?
    /// The running request's cancellation flag and event route. Held so
    /// `stopCurrentGeneration()` can cancel without calling into a runtime that
    /// is blocked inside a synchronous generate.
    private var currentSession: GenerationSession?
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
        engineRegistry: EngineRegistry = EngineRegistry()
    ) {
        self.imageRepository = imageRepository
        self.modelRepository = modelRepository
        self.engineRegistry = engineRegistry
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
        await updateGenerationState(.canceling(nil))
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
    /// Deliberately does not consult `GenerationState`. It used to return unless
    /// the state was `.ready`, which stranded work permanently: nothing outside
    /// this actor ever restores `.ready`, so once a failure left `.error` — an
    /// unwritable images folder, say — every later request was appended to a queue
    /// no drain would ever start. The guard could not serve its apparent purpose
    /// either, since `startProcessingIfNeeded` already refuses to start a second
    /// drain while one is running, and that is the only way the state can be
    /// `.loading` or `.running` here. Queue readiness is not a UI status.
    ///
    /// A stale `.error` heals on its own: the first thing a started request does is
    /// report `.loading`.
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

            let session = GenerationSession(requestID: request.id)
            currentSession = session
            var restoreReadyAfterCancel = false
            do {
                let outputDirectory = try await imageRepository.ensureOutputDirectory(
                    imageDir: request.imageDir
                )
                nextImageIndex = await MainActor.run { ImageGallery.shared.images.endIndex + 1 }

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
                // request. Previously each callback spawned its own task, so two
                // progress updates had no defined order between them.
                let forwarding = Task { [weak self] in
                    for await event in session.events {
                        await self?.apply(event, for: request.id)
                    }
                }
                // Not a `defer`: closing the stream and joining the drain has to
                // happen on both the success and failure paths, and `defer` cannot
                // await. The outcome is held and rethrown afterwards so the
                // existing per-error handling below still sees it.
                let outcome: Result<Void, any Error>
                do {
                    try await runtime.run(
                        request: request,
                        session: session,
                        onResult: { [weak self] result in
                            guard let self else { return }
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
                                imageURL: path
                            )
                            await self.emitResultForCurrentRequest(savedResult)
                        }
                    )
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                // Finish the stream rather than cancelling the drain, so events
                // already emitted are still applied, then wait for the drain to
                // end. Past this point no event from this request can be in
                // flight, which is what lets the next request reuse the UI state.
                session.close()
                await forwarding.value
                try outcome.get()
                // The terminal state belongs here rather than to the runtime, so a
                // dropped event cannot leave the UI stuck mid-generation.
                if !isCancelRequested(for: request.id) {
                    await updateStatus(.ready(nil))
                }
                restoreReadyAfterCancel = true
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
        if image == nil {
            // Keep the last preview frame visible until result insertion/teardown.
            if current?.id == requestID, !isCancelRequested(for: requestID) {
                return
            }
            guard current?.id == requestID || current == nil else { return }
            await setCurrentGeneratingImage(nil)
            return
        }

        guard current?.id == requestID else { return }
        if isCancelRequested(for: requestID), image != nil {
            return
        }

        await setCurrentGeneratingImage(image)
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

    private func setCurrentGeneratingImage(_ image: CGImage?) async {
        await MainActor.run {
            ImageGallery.shared.setCurrentGenerating(image: image)
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
            await setCurrentGeneratingImage(nil)
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
