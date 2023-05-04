//
//  SDModelAttentionType.swift
//  Mochi Diffusion
//
//  Created by Váradi Zsolt on 2023. 03. 29..
//

import CoreML
import Foundation

enum SDModelAttentionType: Hashable, Equatable {
    case splitEinsum
    case original

    var preferredComputeUnits: MLComputeUnits {
        switch self {
        case .original:
            return .cpuAndGPU
        case .splitEinsum:
            return .cpuAndNeuralEngine
        }
    }
}
