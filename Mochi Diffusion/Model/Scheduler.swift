//
//  Scheduler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/9/23.
//

import Schedulers

/// Schedulers compatible with StableDiffusionPipeline
enum Scheduler: String, CaseIterable {
    /// Scheduler that uses a pseudo-linear multi-step (PLMS) method
    case lcm = "LCM"
    /// Scheduler that uses a second order DPM-Solver++ algorithm
    case dpmSolverMultistep = "DPM++ 2M"
    
    case dpmSolverMultistepKarras = "DPM++ 2M Karras"
    
    case dpmSolverSinglestepKarras = "DPM++ SDE Karras"
    
    case eulerAncenstralDiscrete = "Euler Ancenstral"
}

func convertScheduler(_ scheduler: Scheduler) -> Schedulers {
    switch scheduler {
    case .lcm:
        return Schedulers.lcm
    case .dpmSolverMultistep:
        return Schedulers.dpmSolverMultistep
    case .dpmSolverMultistepKarras:
        return Schedulers.dpmSolverMultistepKarras
    case .dpmSolverSinglestepKarras:
        return Schedulers.dpmSolverSinglestepKarras
    case .eulerAncenstralDiscrete:
        return Schedulers.eulerAncenstralDiscrete
    }
}
