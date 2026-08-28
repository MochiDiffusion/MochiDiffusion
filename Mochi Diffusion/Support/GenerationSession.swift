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
    /// Why a session stopped early.
    ///
    /// Both stop the work the same way — the runtime polls ``isCancelled`` — but
    /// they are not the same outcome and the queue reports them differently. A
    /// cancellation is what the user asked for; an expiry is a failure they did
    /// not, and for a hosted service it may still be billed.
    enum StopReason: Sendable, Equatable {
        case cancelled
        case expired
    }

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
    private var stopReasonValue: StopReason?
    private var cancellationHandlers: [@Sendable () -> Void] = []
    /// When this session last showed a sign of life. Read by the idle watchdog,
    /// which is why it lives here rather than in the queue: events arrive on
    /// whatever thread the engine is running on, and the queue cannot observe
    /// them synchronously.
    private var lastActivity: ContinuousClock.Instant

    init(requestID: GenerationRequest.ID) {
        self.requestID = requestID
        lastActivity = ContinuousClock.now
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
        return stopReasonValue != nil
    }

    /// Why the session stopped, or `nil` if it has not. The queue reads this to
    /// tell a cancellation from an expiry; a runtime only needs ``isCancelled``.
    var stopReason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReasonValue
    }

    /// How long since the last event, result, or start. The idle watchdog's
    /// only input.
    var idleDuration: Duration {
        lock.lock()
        defer { lock.unlock() }
        return ContinuousClock.now - lastActivity
    }

    /// Records a sign of life.
    ///
    /// Called for every event, and by whoever delivers a result — results do not
    /// travel as events (see ``GenerationEvent``), and a run that is producing
    /// images one per minute is working, not stalled.
    func noteActivity() {
        lock.lock()
        lastActivity = ContinuousClock.now
        lock.unlock()
    }

    /// Requests cancellation. Idempotent, and returns whether this call was the
    /// one that set the flag, so a caller can avoid repeating the side effects of
    /// cancelling twice.
    @discardableResult
    func cancel() -> Bool {
        stop(because: .cancelled)
    }

    /// Stops the session because it went quiet for too long.
    ///
    /// Deliberately a sibling of ``cancel()`` rather than a flag beside it: the
    /// stopping mechanism has to be identical — the same handlers fire, so a C
    /// library still gets its poke — while the reason has to be distinguishable,
    /// because the queue reports an expiry as a failure and a cancellation as the
    /// user's own doing.
    @discardableResult
    func expire() -> Bool {
        stop(because: .expired)
    }

    /// First reason wins. A user cancelling a request that has already expired,
    /// or the reverse, does not re-run the handlers or change what is reported.
    private func stop(because reason: StopReason) -> Bool {
        lock.lock()
        if stopReasonValue != nil {
            lock.unlock()
            return false
        }
        stopReasonValue = reason
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
    /// Runs immediately if the session has already stopped, so registration
    /// cannot race past a stop that already happened. Expiry counts: a stalled
    /// hosted request needs the same poke a cancelled one does.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if stopReasonValue != nil {
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
        lastActivity = ContinuousClock.now
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
