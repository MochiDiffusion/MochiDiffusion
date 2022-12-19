//
//  Functions.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/17/2022.
//

import Foundation

var docDir: URL? {
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
}

func getHumanReadableInfo(sdi: SDImage) -> String {
    return """
        Prompt:
        \(sdi.prompt)
        
        Negative Prompt:
        \(sdi.negativePrompt)
        
        Size:
        \(sdi.width) x \(sdi.height)
        
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
        
        Model:
        \(sdi.model)
        """
}
