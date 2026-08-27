//
//  Scheduler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/9/23.
//

import StableDiffusion

/// Schedulers compatible with StableDiffusionPipeline
///
/// **The raw value is a stable identifier, not display text.** It is persisted in
/// `UserDefaults` and written into image metadata, so renaming one orphans a
/// user's preference and stops their existing images from parsing. Read
/// `displayName` for anything shown on screen.
///
/// The two read the same today, which is how a display string ends up
/// load-bearing. Keeping them separate means a label can be reworded or localised
/// without touching stored data.
nonisolated enum Scheduler: String, CaseIterable, Sendable {
    /// Scheduler that uses a pseudo-linear multi-step (PLMS) method
    case pndmScheduler = "PNDM"
    /// Scheduler that uses a second order DPM-Solver++ algorithm
    case dpmSolverMultistepScheduler = "DPM-Solver++"
    /// Scheduler for rectified flow based multimodal diffusion transformer models
    case discreteFlowScheduler = "Flow Match Euler Discrete"

    /// What the user sees. Free to be reworded or localised without touching what
    /// is on disk.
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
