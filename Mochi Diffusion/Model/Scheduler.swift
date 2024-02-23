//
//  Scheduler.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/9/23.
//

import Schedulers

/// Schedulers compatible with StableDiffusionPipeline
enum Scheduler: String, CaseIterable {
    case ddim = "DDIM"
    
    case dpmSolverMultistep = "DPM++ 2M"
    
    case dpmSolverMultistepKarras = "DPM++ 2M Karras"
    
    case dpmSolverSinglestep = "DPM++ SDE"
    
    case dpmSolverSinglestepKarras = "DPM++ SDE Karras"

    case eulerDiscrete = "Euler"
    
    case eulerDiscreteKarras = "Euler Karras"
    
    case eulerAncenstralDiscrete = "Euler Ancenstral"
    
    case lcm = "LCM"
}

func convertScheduler(_ scheduler: Scheduler) -> Schedulers {
    switch scheduler {
    case .ddim:
        return Schedulers.ddim
    case .dpmSolverMultistep:
        return Schedulers.dpmSolverMultistep
    case .dpmSolverMultistepKarras:
        return Schedulers.dpmSolverMultistepKarras
    case .dpmSolverSinglestep:
        return Schedulers.dpmSolverSinglestep
    case .dpmSolverSinglestepKarras:
        return Schedulers.dpmSolverSinglestepKarras
    case .eulerDiscrete:
        return Schedulers.eulerDiscrete
    case .eulerDiscreteKarras:
        return Schedulers.eulerDiscreteKarras
    case .eulerAncenstralDiscrete:
        return Schedulers.eulerAncenstralDiscrete
    case .lcm:
        return .lcm
    }
}
