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
/// ``displayName`` for anything shown on screen.
///
/// The two happen to read the same today, which is exactly how a display string
/// ends up load-bearing: §6 of `Multi-Engine-Design.md` requires choice
/// constraints to carry stable ids separately from labels, and using `rawValue`
/// for both meant the first attempt to localise or rename a scheduler would have
/// silently broken stored data. Splitting them now costs nothing and no
/// migration, because the identifiers do not change.
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
