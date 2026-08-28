//
//  FailureReportingTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins what the outcome alert is given to report. The interesting properties are
/// not that a failure is recorded, but that a batch ending the same way ten times
/// is still one thing to report, and that an outcome survives the next request
/// overwriting `state` — which is how a rate-limited generation used to fail in
/// silence.
///
/// Uses its own `GenerationState` rather than the shared one: the singleton is
/// written to by services still finishing in other suites.
@MainActor
struct FailureReportingTests {
    @Test("A terminal message is held for reporting; progress and stage text are not")
    func onlyOutcomesAreHeld() {
        let state = GenerationState()

        state.report(.loading("Loading the model"))
        state.report(.running(GenerationState.Progress(step: 1, stepCount: 4)))
        state.report(.canceling("Stopping"))
        state.report(.ready(nil))
        #expect(state.unreportedOutcomes.isEmpty)

        state.report(.error("Couldn't access images folder at: /nope"))
        #expect(state.unreportedOutcomes == ["Couldn't access images folder at: /nope"])
    }

    /// The regression. A rate limit and a refusal are reported through `.ready`
    /// because they are not malfunctions, and that used to mean the only trace of
    /// them was a `state` the next request overwrote.
    @Test("An outcome that is not a malfunction is still reported")
    func newsIsReportedToo() {
        let state = GenerationState()

        state.report(.ready("gpt-image-2 is rate limiting requests. Try again shortly."))

        #expect(
            state.unreportedOutcomes == [
                "gpt-image-2 is rate limiting requests. Try again shortly."
            ]
        )
    }

    /// The mechanism of that silence: the next request in the batch reports
    /// `.loading`, and later `.ready(nil)`, both of which clear the message from
    /// `state`. The report has to outlive them.
    @Test("A later request cannot erase an outcome before it is reported")
    func outcomeSurvivesTheNextRequest() {
        let state = GenerationState()

        state.report(.ready("gpt-image-2 is rate limiting requests. Try again shortly."))
        state.report(.loading(nil))
        state.report(.running(GenerationState.Progress(step: 2, stepCount: 4)))
        state.report(.ready(nil))

        #expect(state.state == .ready(nil))
        #expect(
            state.unreportedOutcomes == [
                "gpt-image-2 is rate limiting requests. Try again shortly."
            ]
        )
    }

    @Test("A batch ending the same way is one outcome to report")
    func identicalOutcomesCollapse() {
        let state = GenerationState()

        for _ in 0..<10 {
            state.report(.loading(nil))
            state.report(.error("Couldn't sign in to gpt-image-2."))
        }

        #expect(state.unreportedOutcomes.count == 1)
    }

    @Test("A batch ending two ways reports both, in the order they happened")
    func distinctOutcomesAccumulate() {
        let state = GenerationState()

        state.report(.error("a malfunction"))
        state.report(.ready("news"))
        state.report(.error("a malfunction"))

        #expect(state.unreportedOutcomes == ["a malfunction", "news"])
    }

    /// Dismissing used to clear the deduplication outright, so a user who
    /// dismissed eagerly got one alert per failing request — ten alerts for the
    /// ten identical failures this is supposed to collapse.
    @Test("Dismissing silences that outcome for the rest of the batch")
    func dismissalSticksWithinTheBatch() {
        let state = GenerationState()

        state.report(.error("a failure"))
        state.clearUnreportedOutcomes()
        #expect(state.unreportedOutcomes.isEmpty)

        state.report(.loading(nil))
        state.report(.error("a failure"))
        #expect(state.unreportedOutcomes.isEmpty)
    }

    @Test("Dismissing one outcome does not silence a different one")
    func dismissalIsPerMessage() {
        let state = GenerationState()

        state.report(.error("a failure"))
        state.clearUnreportedOutcomes()

        state.report(.error("a different failure"))
        #expect(state.unreportedOutcomes == ["a different failure"])
    }

    /// "A new batch" is the user asking again, which is also what rescues the
    /// failure that happens before anything is enqueued: an unwritable images
    /// folder starts no drain, so without this every click after the first would
    /// be silent.
    @Test("Asking again reports an outcome dismissed during the last attempt")
    func aNewBatchReportsAgain() {
        let state = GenerationState()

        state.report(.error("a failure"))
        state.clearUnreportedOutcomes()

        state.noteBatchStarted()
        state.report(.error("a failure"))
        #expect(state.unreportedOutcomes == ["a failure"])
    }

    /// Why the batch boundary is the start of a drain and not the end: the alert
    /// outlives the drain that raised it, so a batch beginning must not throw away
    /// an outcome still waiting to be read.
    @Test("A new batch keeps an outcome that has not been reported yet")
    func aNewBatchKeepsUnreadOutcomes() {
        let state = GenerationState()

        state.report(.error("a failure"))
        state.noteBatchStarted()

        #expect(state.unreportedOutcomes == ["a failure"])
    }

    /// `state` stays the source of truth for the status popover and the toolbar.
    /// Recording the outcome must not disturb it.
    @Test("Reporting still sets the status")
    func statusIsStillSet() {
        let state = GenerationState()

        state.report(.error("a failure"))
        #expect(state.state == .error("a failure"))

        state.report(.ready(nil))
        #expect(state.state == .ready(nil))
    }
}
