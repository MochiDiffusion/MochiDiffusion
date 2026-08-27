//
//  IrisSingleFlightTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Records who held the lease and when, so exclusivity is asserted rather than
/// assumed.
private actor LeaseLog {
    private(set) var peakConcurrent = 0
    private(set) var order: [String] = []
    private var concurrent = 0

    func entered(_ label: String) {
        concurrent += 1
        peakConcurrent = max(peakConcurrent, concurrent)
        order.append(label)
    }

    func left() {
        concurrent -= 1
    }

    func note(_ label: String) {
        order.append(label)
    }
}

/// Pins the guarantee an actor does *not* provide.
///
/// Actors are reentrant at every suspension point, and `IrisEngineRuntime.run`
/// suspends on the embedding cache, on encoding, and on delivering results. Making
/// it an actor therefore does not stop a second call interleaving and resetting the
/// C library's process-global callback route and cancel flag under a request that
/// still owns a context.
struct IrisSingleFlightTests {

    @Test("An uncontended lease is taken immediately")
    func uncontendedAcquire() async {
        let lease = IrisSingleFlight()

        await lease.acquire()
        #expect(await lease.isCurrentlyHeld)

        await lease.release()
        #expect(await !lease.isCurrentlyHeld)
    }

    /// The property that matters: two holders never coexist, even though each
    /// suspends in the middle of its critical section — which is the shape of
    /// `run`, and the reason being an actor was not enough.
    @Test("Overlapping holders never coexist")
    func holdersAreExclusive() async {
        let lease = IrisSingleFlight()
        let log = LeaseLog()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await lease.acquire()
                    await log.entered("\(index)")
                    // Suspends while holding, like every `await` inside `run`.
                    await Task.yield()
                    await Task.yield()
                    await log.left()
                    await lease.release()
                }
            }
        }

        #expect(await log.peakConcurrent == 1)
        #expect(await !lease.isCurrentlyHeld)
    }

    /// The C state is per process, not per instance, so two runtimes sharing the
    /// singleton have to serialize against each other too.
    @Test("A waiter cannot barge in ahead of the holder")
    func waiterWaitsForRelease() async {
        let lease = IrisSingleFlight()
        let log = LeaseLog()

        await lease.acquire()
        await log.note("first-in")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await lease.acquire()
                await log.note("second-in")
                await lease.release()
            }

            // Every chance for the waiter to run before the release.
            for _ in 0..<20 { await Task.yield() }
            await log.note("first-out")
            await lease.release()
        }

        #expect(await log.order == ["first-in", "first-out", "second-in"])
    }

    @Test("Releasing an unheld lease does not wedge it")
    func releaseWithoutAcquireIsHarmless() async {
        let lease = IrisSingleFlight()

        await lease.release()
        await lease.acquire()

        #expect(await lease.isCurrentlyHeld)
        await lease.release()
    }
}
