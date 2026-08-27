//
//  GenerationSession.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// Progress reported while a request runs, other than its results.
///
/// One channel instead of the three separate `onState`/`onProgress`/`onPreview`
/// callbacks it replaces. Those had to be reasoned about three times over for
/// lifetime, ordering and stale delivery, and each was a place a late Iris C
/// callback could reach the wrong request.
///
/// Results are deliberately *not* here. They are the one channel that must not be
/// dropped, that has to apply back-pressure — the caller writes the file before
/// the engine produces the next image — and that has to be able to fail the
/// generation when the write fails. They also never arrive late, because they are
/// emitted from the generation loop rather than from a C callback. So results stay
/// an awaited throwing call and the lossy events become a stream.
nonisolated enum GenerationEvent: Sendable {
    /// A phase label — "Loading model…", "Encoding prompt…". Informational only:
    /// the terminal `.ready` and `.error` states belong to whoever ran the
    /// session, so losing one of these can never strand the UI.
    case state(GenerationState.Status)
    case progress(GenerationState.Progress)
    /// `nil` clears the preview.
    case preview(CGImage?)
}

/// One queued request's cancellation flag and event route.
///
/// Created by whoever runs the request, handed to the engine runtime, and closed
/// when the request finishes. Its identity is the request's, so an event or a
/// cancel can always be checked against the request it was meant for.
///
/// A lock-protected class rather than an actor, for two reasons that are not about
/// convenience:
///
/// - **The callbacks are synchronous.** Core ML's progress handler returns `Bool`
///   to continue or stop, and the Iris C step callbacks return `Void`, both on the
///   thread running generation. They have to read cancellation and emit progress
///   without awaiting, because there is nothing to await into — the generation
///   call that invoked them holds the thread.
/// - **Cancelling must not queue behind generating.** An engine runtime that ran a
///   blocking `generateImages` on its own actor executor could not accept a
///   `cancel()` call until generation returned, so cancellation would quietly
///   stop working. Keeping the flag on a value the canceller already holds means
///   cancelling never touches the runtime at all.
///
/// `@unchecked Sendable` is honest here: every mutable field is guarded by this
/// type's own lock. That is the distinction §11.3 of `Multi-Engine-Design.md`
/// draws — the invariant is enforced by the type itself, not asserted about some
/// other type's behaviour, which is what the old generator conformances did when
/// they claimed `GenerationService` serialized them.
nonisolated final class GenerationSession: @unchecked Sendable {
    let requestID: GenerationRequest.ID

    /// Bounded rather than unbounded. Every event here is lossy by nature: a
    /// superseded progress step or preview frame has no value, and previews are
    /// full-size images, so an unbounded buffer in front of a suspended consumer
    /// would grow without limit. The bound is generous — the consumer only
    /// forwards to `GenerationState` — so in practice nothing is dropped.
    let events: AsyncStream<GenerationEvent>

    private let lock = NSLock()
    private var continuation: AsyncStream<GenerationEvent>.Continuation?
    private var isCancelledFlag = false
    private var cancellationHandlers: [@Sendable () -> Void] = []

    init(requestID: GenerationRequest.ID) {
        self.requestID = requestID
        var escapedContinuation: AsyncStream<GenerationEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            escapedContinuation = continuation
        }
        continuation = escapedContinuation
    }

    /// Whether generation should stop. Safe to call from a synchronous callback on
    /// any thread, and never blocks on the runtime.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }

    /// Requests cancellation. Idempotent, and returns whether this call was the
    /// one that set the flag, so a caller can avoid repeating the side effects of
    /// cancelling twice.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        if isCancelledFlag {
            lock.unlock()
            return false
        }
        isCancelledFlag = true
        let handlers = cancellationHandlers
        cancellationHandlers = []
        lock.unlock()
        // Outside the lock: a handler pokes a C library, and holding the lock
        // across that would let a callback that wants to emit deadlock against
        // the thread cancelling it.
        for handler in handlers {
            handler()
        }
        return true
    }

    /// Registers work to run the moment cancellation is requested, on the
    /// cancelling thread.
    ///
    /// Polling `isCancelled` is enough for an engine whose generation loop asks
    /// between steps — Core ML's progress handler returns `Bool` for exactly that.
    /// It is not enough for one that has to be interrupted from outside: Iris runs
    /// its loop inside a C call that only stops when `iris_request_cancel()` sets
    /// the library's own flag, and the runtime cannot call it because it is inside
    /// that call. Registering the poke here is what keeps cancellation from having
    /// to reach a blocked runtime.
    ///
    /// Runs immediately if the session is already cancelled, so registration
    /// cannot race past a cancel that already happened.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCancelledFlag {
            lock.unlock()
            handler()
            return
        }
        cancellationHandlers.append(handler)
        lock.unlock()
    }

    /// Emits an event, or drops it if the session is closed.
    ///
    /// Dropping after close is the point: it is the single checkpoint where an
    /// event from a finished request is discarded, rather than three checkpoints
    /// that each had to remember to check.
    func emit(_ event: GenerationEvent) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(event)
    }

    /// Ends the event stream and drops anything emitted afterwards.
    ///
    /// Called exactly once, by whoever created the session, after the runtime has
    /// returned. A C callback that fires during teardown may still reach `emit`;
    /// it finds no continuation and goes nowhere, instead of arriving at the next
    /// request.
    func close() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        cancellationHandlers = []
        lock.unlock()
        continuation?.finish()
    }
}
