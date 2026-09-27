//
//  SchedulerTests.swift
//  Mochi DiffusionTests
//

import StableDiffusion
import Testing

@testable import Mochi_Diffusion

/// Pins the mapping from Mochi's scheduler choice to the Core ML pipeline's.
struct SchedulerTests {
    @Test(
        "Each scheduler maps to the pipeline scheduler of the same name",
        arguments: Mochi_Diffusion.Scheduler.allCases
    )
    func mapsToPipelineScheduler(scheduler: Mochi_Diffusion.Scheduler) {
        let expected: StableDiffusionScheduler =
            switch scheduler {
            case .pndmScheduler: .pndmScheduler
            case .dpmSolverMultistepScheduler: .dpmSolverMultistepScheduler
            case .discreteFlowScheduler: .discreteFlowScheduler
            }
        #expect(convertScheduler(scheduler) == expected)
    }
}
