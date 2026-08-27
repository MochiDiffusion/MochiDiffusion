//
//  IrisSingleFlight.swift
//  Mochi Diffusion
//

import Foundation

/// Process-wide gate around the Iris C library, which allows one generation at a
/// time whatever the queue above it does.
///
/// **Making the runtime an actor does not achieve this.** Actors are reentrant at
/// every suspension point, and `IrisEngineRuntime.run(request:session:onResult:)`
/// suspends four times — twice on the embedding cache, once encoding image data,
/// once delivering a result. A second call can enter during any of them and call
/// `iris_clear_cancel()`, install its own callback route and load a second context
/// while the first still owns one. Two runtime instances can overlap for the same
/// reason: the C library's callback slots and cancel flag are per process, not per
/// instance.
///
/// Whoever holds the lease owns the C library until they give it back, so the
/// guarantee does not depend on how many requests the queue above chooses to run.
///
/// Deliberately not a lock: waiting on one would block a cooperative-pool thread
/// for the length of another generation, where waiting for a lease suspends.
actor IrisSingleFlight {
    static let shared = IrisSingleFlight()

    private var isHeld = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// FIFO, so a queue of requests runs in the order it was submitted rather than
    /// in whatever order a dictionary hands its keys back.
    private var waiting: [UUID] = []

    /// Takes the lease, suspending until it is free.
    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            waiting.append(id)
        }
    }

    /// Hands the lease to the next waiter, or releases it.
    ///
    /// Resuming the next waiter directly rather than clearing `isHeld` and letting
    /// it race is what keeps the lease from being handed to two waiters at once.
    func release() {
        guard let next = waiting.first else {
            isHeld = false
            return
        }
        waiting.removeFirst()
        let continuation = waiters.removeValue(forKey: next)
        continuation?.resume()
    }

    /// Whether the lease is currently held. For tests; production code should
    /// acquire rather than ask.
    var isCurrentlyHeld: Bool { isHeld }
}
