//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import Foundation

func getHumanReadableInfo(sdi: SDImage) -> String {
    """
\(Metadata.date.rawValue):
\(sdi.generatedDate.formatted(date: .long, time: .standard))

\(Metadata.model.rawValue):
\(sdi.model)

\(Metadata.size.rawValue):
\(sdi.width) x \(sdi.height)\(sdi.isUpscaled ? " (Converted to High Resolution)" : "")

\(Metadata.includeInImage.rawValue):
\(sdi.prompt)

\(Metadata.excludeFromImage.rawValue):
\(sdi.negativePrompt)

\(Metadata.scheduler.rawValue):
\(sdi.scheduler.rawValue)

\(Metadata.seed.rawValue):
\(sdi.seed)

\(Metadata.steps.rawValue):
\(sdi.steps)

\(Metadata.guidanceScale.rawValue):
\(sdi.guidanceScale)
"""
}
