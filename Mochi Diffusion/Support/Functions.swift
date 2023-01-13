//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import Foundation

func getHumanReadableInfo(sdi: SDImage) -> String {
    return """
Date:
\(sdi.generatedDate.formatted(date: .long, time: .standard))

Model:
\(sdi.model)

Size:
\(sdi.width) x \(sdi.height)\(sdi.isUpscaled ? " (Converted to High Resolution)" : "")

Prompt:
\(sdi.prompt)

Negative Prompt:
\(sdi.negativePrompt)

Scheduler:
\(sdi.scheduler.rawValue)

Seed:
\(sdi.seed)

Steps:
\(sdi.steps)

Guidance Scale:
\(sdi.guidanceScale)
"""
}
