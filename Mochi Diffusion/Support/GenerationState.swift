//
//  GenerationState.swift
//  Mochi Diffusion
//

import Foundation
import Observation

@MainActor
@Observable
final class GenerationState {
    nonisolated enum ProgressKind: Sendable, Equatable {
        case step
        case preview
    }

    /// `nonisolated` because these are pure data that cross isolation on every
    /// generation. Nested in a `@MainActor` type and with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, their members were
    /// main-actor-isolated despite the `Sendable` conformance — so an engine
    /// running off the main actor could construct a `Progress` and hand it over,
    /// but could not read `step` back out of one. Anything that reports progress
    /// from a background context needs both directions.
    nonisolated struct Progress: Sendable, Equatable {
        let step: Int
        let stepCount: Int
        let kind: ProgressKind

        init(step: Int, stepCount: Int, kind: ProgressKind = .step) {
            self.step = step
            self.stepCount = stepCount
            self.kind = kind
        }

        var localizedLabel: String {
            let current = step + 1
            switch kind {
            case .step:
                return String(
                    localized: "Step \(current)/\(stepCount)",
                    comment: "Progress through a model's generation steps"
                )
            case .preview:
                return String(
                    localized: "Preview \(current)/\(stepCount)",
                    comment: "Progress through partial preview images from a hosted service"
                )
            }
        }
    }

    nonisolated enum Status: Sendable, Equatable {
        case ready(String?)
        case error(String)
        case loading(String?)
        case canceling(String?)
        case running(Progress?)

        /// What this status has to tell the user, if anything.
        ///
        /// Only the two terminal cases. `.loading` and `.canceling` carry stage
        /// text, which describes work in progress and is replaced by the next
        /// stage rather than being news to report.
        var outcomeMessage: String? {
            switch self {
            case .error(let message): message
            case .ready(let message): message
            case .loading, .canceling, .running: nil
            }
        }
    }

    static let shared = GenerationState()

    private(set) var state: Status = .ready(nil)

    /// Outcomes the user has not dismissed yet, oldest first.
    ///
    /// Held apart from `state` because `state` is only ever the *current* status,
    /// and the next request overwrites it. A rate limit part-way through a batch
    /// kept its message exactly as long as it took the following request to
    /// report `.loading` — which is to say the generation failed in silence. The
    /// queue also keeps draining after a failure, so ten requests failing the
    /// same way set `.error` ten times, and that should be one alert rather than
    /// ten. Identical messages collapse.
    ///
    /// Every message counts, not only `.error`. A refused prompt or a rate limit
    /// is not a malfunction, but it still ends a request having produced no
    /// image; the register the message is written in is no reason to make the
    /// user go looking for it.
    private(set) var unreportedOutcomes: [String] = []

    /// What the user has dismissed during the batch now draining.
    ///
    /// Dismissing used to clear the deduplication outright, so the next request
    /// failing the same way appended the message again and reopened the alert.
    /// Ten identical failures were one alert only for a user who left it alone
    /// until the queue emptied; anyone dismissing eagerly still got ten.
    /// Acknowledging one silences it for the rest of the batch, and no longer.
    private var acknowledged: Set<String> = []

    /// The only way `state` changes, so an outcome cannot reach the UI without
    /// also being recorded for the alert to report.
    func report(_ status: Status) {
        state = status
        guard let message = status.outcomeMessage else { return }
        guard !acknowledged.contains(message) else { return }
        guard !unreportedOutcomes.contains(message) else { return }
        unreportedOutcomes.append(message)
    }

    func clearUnreportedOutcomes() {
        acknowledged.formUnion(unreportedOutcomes)
        unreportedOutcomes = []
    }

    /// A batch starting forgets what was dismissed during the last one, so a
    /// failure acknowledged an hour ago is reported again rather than suppressed
    /// for the rest of the run.
    ///
    /// Called when the user asks for a generation, not when a drain begins or
    /// ends. Not the end, because the alert outlives the drain that raised it and
    /// that dismissal would land in the next batch. Not the start either: a
    /// request that fails before it is ever enqueued starts no drain, so there
    /// would be nothing to reset it and Generate would go quiet.
    func noteBatchStarted() {
        acknowledged = []
    }
}
