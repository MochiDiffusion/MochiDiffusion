//
//  IrisSingleFlight.swift
//  Mochi Diffusion
//

import Foundation

/// Process-wide gate around the Iris C library, which allows one generation at a
/// time whatever the queue above it does.
///
/// **An actor is not enough for this, which is what makes the type necessary.**
/// `IrisEngineRuntime` is an actor, and Phase 3's commit message claimed that made
/// single-flight structural. It does not: actors are reentrant at every
/// suspension point, and `run` suspends four times — twice on the embedding
/// cache, once encoding image data, once delivering a result. A second `run` can
/// enter during any of them and call `iris_clear_cancel()`, install its own
/// callback route and load a second context while the first request still owns
/// one. Two separate runtime instances can overlap for the same reason, since the
/// C state is per process rather than per instance.
///
/// Nothing hits that today only because `GenerationService` runs one request at a
/// time — the external serialization assumption §11.3 says must not be what an
/// invariant rests on. This makes the guarantee local: whoever holds the lease
/// owns the C library until they give it back.
///
/// Deliberately not a lock. Waiting on a lock would block a cooperative-pool
/// thread for the length of another generation, and the whole point of a lease is
/// that waiting for it is a suspension rather than a stall.
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
