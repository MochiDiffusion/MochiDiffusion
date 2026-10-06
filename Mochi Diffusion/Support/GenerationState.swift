//
//  GenerationState.swift
//  Mochi Diffusion
//

import Foundation
import Observation

@MainActor
@Observable
final class GenerationState {
    /// `nonisolated` because these are pure data that cross isolation on every
    /// generation. Nested in a `@MainActor` type under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, their members would otherwise
    /// be main-actor-isolated despite the `Sendable` conformance, and code off the
    /// main actor could not read them.
    nonisolated struct Progress: Sendable, Equatable {
        let step: Int
        let stepCount: Int

        var localizedLabel: String {
            String(
                localized: "Step \(step + 1)/\(stepCount)",
                comment: "Progress through a model's generation steps"
            )
        }
    }

    nonisolated enum Status: Sendable, Equatable {
        case ready(String?)
        case error(String)
        case loading(String?)
        case canceling
        case running(Progress?)

        /// What this status has to tell the user, if anything.
        ///
        /// Only the two terminal cases. `.loading` carries stage text, which
        /// describes work in progress and is replaced by the next stage rather than
        /// being news to report.
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
    /// Held apart from `state` because `state` is only the *current* status, and
    /// the next request overwrites it. The queue keeps draining after a failure,
    /// so identical messages collapse into one alert.
    ///
    /// Every message counts, not only `.error`. A refused prompt or a rate limit
    /// is not a malfunction, but it still ends a request having produced no image.
    private(set) var unreportedOutcomes: [String] = []

    /// What the user has dismissed during the batch now draining.
    ///
    /// Acknowledging a message silences it for the rest of the batch, so later
    /// requests failing the same way do not reopen the alert.
    private var acknowledged: Set<String> = []

    /// Model lists the alert offers to refresh, because an unreported outcome may
    /// be explained by one being out of date.
    private(set) var outdatedModelListSources: Set<ModelListSource> = []

    /// The only way `state` changes, so an outcome cannot reach the UI without
    /// also being recorded for the alert to report.
    ///
    /// - Parameter outdatedModelListSource: a model list that may explain this
    ///   outcome, which the alert then offers to refresh.
    func report(_ status: Status, outdatedModelListSource: ModelListSource? = nil) {
        state = status
        guard let message = status.outcomeMessage else { return }
        guard !acknowledged.contains(message) else { return }
        if let outdatedModelListSource {
            outdatedModelListSources.insert(outdatedModelListSource)
        }
        guard !unreportedOutcomes.contains(message) else { return }
        unreportedOutcomes.append(message)
    }

    func clearUnreportedOutcomes() {
        acknowledged.formUnion(unreportedOutcomes)
        unreportedOutcomes = []
        outdatedModelListSources = []
    }

    /// A batch starting forgets what was dismissed during the last one.
    ///
    /// Called when the user asks for a generation, not when a drain begins or
    /// ends: the alert outlives the drain that raised it, and a request that fails
    /// before it is enqueued starts no drain.
    func noteBatchStarted() {
        acknowledged = []
    }
}
