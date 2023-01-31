//
//  Metadata.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/31/23.
//

enum Metadata: String, CaseIterable {
    case date = "Date"
    case model = "Model"
    case size = "Size"
    case includeInImage = "Include in Image"
    case excludeFromImage = "Exclude from Image"
    case scheduler = "Scheduler"
    case seed = "Seed"
    case steps = "Steps"
    case guidanceScale = "Guidance Scale"
    case generator = "Generator"
    case upscaler = "Upscaler"
}
