//
//  Scheduler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/9/23.
//

import StableDiffusion

/// Schedulers compatible with StableDiffusionPipeline
///
/// The raw value is a stable identifier, not display text.
/// Read `displayName` for anything shown on screen.
nonisolated enum Scheduler: String, CaseIterable, Sendable {
    /// Scheduler that uses a pseudo-linear multi-step (PLMS) method
    case pndmScheduler = "PNDM"
    /// Scheduler that uses a second order DPM-Solver++ algorithm
    case dpmSolverMultistepScheduler = "DPM-Solver++"
    /// Scheduler for rectified flow based multimodal diffusion transformer models
    case discreteFlowScheduler = "Flow Match Euler Discrete"

    var displayName: String {
        switch self {
        case .pndmScheduler: return "PNDM"
        case .dpmSolverMultistepScheduler: return "DPM-Solver++"
        case .discreteFlowScheduler: return "Flow Match Euler Discrete"
        }
    }
}

nonisolated func convertScheduler(_ scheduler: Scheduler) -> StableDiffusionScheduler {
    switch scheduler {
    case .pndmScheduler:
        return StableDiffusionScheduler.pndmScheduler
    case .dpmSolverMultistepScheduler:
        return StableDiffusionScheduler.dpmSolverMultistepScheduler
    case .discreteFlowScheduler:
        return StableDiffusionScheduler.discreteFlowScheduler
    }
}
