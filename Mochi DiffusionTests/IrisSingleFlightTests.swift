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

    @Test(
        "A loaded context is kept only for the directory it came from",
        arguments: [
            (loaded: "/models/klein", requested: "/models/klein", keeps: true),
            (loaded: "/models/klein", requested: "/models/zimage", keeps: false),
            (loaded: nil, requested: "/models/klein", keeps: false),
        ] as [(loaded: String?, requested: String, keeps: Bool)],
        [false, true]
    )
    func contextReuseFollowsTheModelDirectory(
        directories: (loaded: String?, requested: String, keeps: Bool), reduceMemory: Bool
    ) {
        // A cached prompt for a model that uses the cache, so only the directory
        // decides.
        let keeps = IrisEngineRuntime.keepsLoadedContext(
            loadedModelDir: directories.loaded,
            for: directories.requested,
            reduceMemory: reduceMemory,
            family: .zImageTurbo,
            referenceCount: 0,
            promptIsCached: true
        )
        #expect(keeps == directories.keeps)
    }

    /// With Reduce Memory Usage on, a kept model survives only a request that
    /// leaves the text encoder unloaded; off, the same model is always kept.
    @Test(
        "Reduce Memory Usage keeps the model only when the text encoder stays unloaded",
        arguments: [
            (family: IrisModelFamily.zImageTurbo, references: 0, cached: true, keeps: true),
            (family: .zImageTurbo, references: 0, cached: false, keeps: false),
            (family: .fluxKlein, references: 1, cached: true, keeps: true),
            (family: .fluxKlein, references: 1, cached: false, keeps: false),
            // iris_multiref encodes the prompt itself.
            (family: .fluxKlein, references: 2, cached: true, keeps: false),
            // A guidance-running model encodes inside iris_generate.
            (family: .fluxKleinBase, references: 0, cached: true, keeps: false),
        ] as [(family: IrisModelFamily, references: Int, cached: Bool, keeps: Bool)]
    )
    func reduceMemoryFreesBeforeEncoding(
        request: (family: IrisModelFamily, references: Int, cached: Bool, keeps: Bool)
    ) {
        func keeps(reduceMemory: Bool) -> Bool {
            IrisEngineRuntime.keepsLoadedContext(
                loadedModelDir: "/models/m",
                for: "/models/m",
                reduceMemory: reduceMemory,
                family: request.family,
                referenceCount: request.references,
                promptIsCached: request.cached
            )
        }
        #expect(keeps(reduceMemory: true) == request.keeps)
        #expect(keeps(reduceMemory: false))
    }

    /// With nothing loaded there is nothing to free, so the drain must not wait for
    /// a lease another generation may hold.
    @Test("Draining with no context loaded does not wait for the lease", .timeLimit(.minutes(1)))
    func drainWithNothingLoadedSkipsTheLease() async {
        await IrisSingleFlight.shared.acquire()
        await IrisEngineRuntime().queueDrained()
        await IrisSingleFlight.shared.release()
    }
}
