//
//  IrisSingleFlight.swift
//  Mochi Diffusion
//

import Foundation

/// Process-wide gate around the Iris C library, which allows one generation at a
/// time whatever the queue above it does.
///
/// The library's callback slots and cancel flag are per process, not per instance,
/// so actor isolation on the runtime is not sufficient: actors are reentrant at
/// every suspension point, and `IrisEngineRuntime.run` suspends several times. A
/// second call entering during one of them would clear the cancel flag, install
/// its own callback route, and load a second context while the first still holds
/// one. Whoever holds the lease owns the library until they give it back.
///
/// An actor rather than a lock, so waiting suspends instead of blocking a
/// cooperative-pool thread for the length of another generation.
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
