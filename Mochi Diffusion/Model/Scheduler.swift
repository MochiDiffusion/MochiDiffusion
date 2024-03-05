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
    
    case dpm2 = "DPM2"

    case dpm2Karras = "DPM2 Karras"
    
    case eulerDiscrete = "Euler"
    
    case eulerDiscreteKarras = "Euler Karras"
    
    case eulerAncestralDiscrete = "Euler Ancestral"
    
    case lcm = "LCM"
    
    case pndm = "PNDM"
}

func convertScheduler(_ scheduler: Scheduler) -> Schedulers {
    switch scheduler {
    case .ddim:
        return .ddim
    case .dpmSolverMultistep:
        return .dpmSolverMultistep
    case .dpmSolverMultistepKarras:
        return .dpmSolverMultistepKarras
    case .dpmSolverSinglestep:
        return .dpmSolverSinglestep
    case .dpmSolverSinglestepKarras:
        return .dpmSolverSinglestepKarras
    case .dpm2:
        return .dpm2
    case .dpm2Karras:
        return .dpm2Karras
    case .eulerDiscrete:
        return .eulerDiscrete
    case .eulerDiscreteKarras:
        return .eulerDiscreteKarras
    case .eulerAncestralDiscrete:
        return .eulerAncestralDiscrete
    case .lcm:
        return .lcm
    case .pndm:
        return .pndm
    }
}
