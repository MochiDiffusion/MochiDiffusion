//
//  GenerationState.swift
//  Mochi Diffusion
//

import Foundation
import Observation

@MainActor
@Observable
final class GenerationState {
    struct Progress: Sendable, Equatable {
        let step: Int
        let stepCount: Int
    }

    enum Status: Sendable, Equatable {
        case ready(String?)
        case error(String)
        case loading
        case running(Progress?)
    }

    static let shared = GenerationState()

    var state: Status = .ready(nil)
    var lastStepGenerationElapsedTime: Double?
}
