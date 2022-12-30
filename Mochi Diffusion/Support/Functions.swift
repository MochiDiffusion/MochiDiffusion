//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import Foundation

let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.timeZone = TimeZone.autoupdatingCurrent
    formatter.dateStyle = .long
    formatter.timeStyle = .medium
    formatter.doesRelativeDateFormatting = true
    return formatter
}()

func getHumanReadableInfo(sdi: SDImage) -> String {
    return """
Date:
\(dateFormatter.string(from: sdi.generatedDate))

Model:
\(sdi.model)

Size:
\(sdi.width) x \(sdi.height)

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

Image Index:
\(sdi.imageIndex)
"""
}
