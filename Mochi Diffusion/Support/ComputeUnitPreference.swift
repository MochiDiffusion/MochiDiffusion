//
//  ComputeUnitPreference.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML

/// `nonisolated` because it is a pure mapping from a preference and a model's
/// attention type to a compute unit. It was main-actor-isolated only by the
/// project's default isolation, never by need; the Core ML engine resolves it
/// inside `plan`, which is nonisolated.
nonisolated enum ComputeUnitPreference: String {
    case auto
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all

    init?(exact computeUnits: MLComputeUnits) {
        switch computeUnits {
        case .cpuAndGPU: self = .cpuAndGPU
        case .cpuAndNeuralEngine: self = .cpuAndNeuralEngine
        case .all: self = .all
        default: return nil
        }
    }

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
