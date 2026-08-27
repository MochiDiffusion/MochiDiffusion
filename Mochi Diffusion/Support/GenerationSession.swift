//
//  GenerationSession.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// Progress reported while a request runs, other than its results.
///
/// Every case here is lossy: a superseded progress step or preview frame has no
/// value, so all three share one stream and one stale-delivery checkpoint.
///
/// Results are deliberately not among them. A result must never be dropped, it
/// applies back-pressure — the caller writes each file before the engine produces
/// the next image — and a failed write has to fail the generation, which needs a
/// call that can throw back into the generation loop. Results are also emitted
/// from the generation loop rather than from a C callback, so they cannot arrive
/// late. See `GenerationEngineRuntime.run(request:session:onResult:)`.
nonisolated enum GenerationEvent: Sendable {
    /// A phase label such as "Loading model…". Informational only: the terminal
    /// `.ready` and `.error` states belong to whoever ran the session, so losing
    /// one of these cannot strand the UI.
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
/// Lock-protected rather than an actor, for two reasons:
///
/// - **The generation callbacks are synchronous.** Core ML's progress handler
///   returns `Bool` to continue or stop, and the Iris C step callbacks return
///   `Void`, both on the thread running generation. They must read cancellation
///   and emit progress without awaiting, because there is nothing to await into:
///   the generation call that invoked them holds the thread.
/// - **Cancelling must not queue behind generating.** A runtime that runs a
///   blocking `generateImages` on its own actor executor cannot accept a call
///   until generation returns, so an actor-isolated `cancel` would compile and
///   never arrive. Keeping the flag on a value the canceller already holds means
///   cancelling never touches the runtime.
///
/// `@unchecked Sendable` is sound because every mutable field is guarded by this
/// type's own lock.
nonisolated final class GenerationSession: @unchecked Sendable {
    let requestID: GenerationRequest.ID

    /// Progress, phase and preview events for this request.
    ///
    /// Bounded: previews are full-size images, so an unbounded buffer in front of
    /// a suspended consumer would grow without limit. The bound is generous
    /// enough that nothing is dropped in practice, and every event is lossy if it
    /// were.
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
    /// Polling `isCancelled` suffices for an engine whose loop asks between
    /// steps, as Core ML's progress handler does. It does not for one that must be
    /// interrupted from outside: Iris runs its loop inside a C call that stops
    /// only when `iris_request_cancel()` sets the library's flag, and the runtime
    /// cannot call it from inside that call.
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
    /// This is the single checkpoint at which an event from a finished request is
    /// discarded.
    func emit(_ event: GenerationEvent) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(event)
    }

    /// Ends the event stream and drops anything emitted afterwards.
    ///
    /// Call once, after the runtime has returned. A C callback firing during
    /// teardown may still reach `emit(_:)`; it finds no continuation and goes
    /// nowhere rather than arriving at the next request.
    func close() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        cancellationHandlers = []
        lock.unlock()
        continuation?.finish()
    }
}
