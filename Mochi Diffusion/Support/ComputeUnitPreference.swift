//
//  ComputeUnitPreference.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML

enum ComputeUnitPreference: String {
    case auto
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all

    func computeUnits(forModel model: SDModel) -> MLComputeUnits {
        switch self {
        case .auto:
            return model.attention.preferredComputeUnits
        case .cpuAndGPU:
            return .cpuAndGPU
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        case .all:
            return .all
        }
    }
}
