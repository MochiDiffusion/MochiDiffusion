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
    /// generation. Nested in a `@MainActor` type and with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, their members were
    /// main-actor-isolated despite the `Sendable` conformance — so an engine
    /// running off the main actor could construct a `Progress` and hand it over,
    /// but could not read `step` back out of one. Anything that reports progress
    /// from a background context needs both directions.
    nonisolated struct Progress: Sendable, Equatable {
        let step: Int
        let stepCount: Int
    }

    nonisolated enum Status: Sendable, Equatable {
        case ready(String?)
        case error(String)
        case loading(String?)
        case canceling(String?)
        case running(Progress?)
    }

    static let shared = GenerationState()

    var state: Status = .ready(nil)
}
