//
//  MainViewStatus.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import StableDiffusion

enum MainViewStatus {
    case idle
    case ready(String)
    case error(String)
    case loading
    case running(StableDiffusionProgress?)
}
