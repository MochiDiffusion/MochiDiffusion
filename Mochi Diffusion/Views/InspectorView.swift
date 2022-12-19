//
//  InspectorView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct InspectorView: View {
    var image: Binding<SDImage?>
    
    var body: some View {
        if let sdi = image.wrappedValue {
            VStack(alignment: .leading) {
                let info = """
                Prompt:
                \(sdi.prompt)
                
                Negative Prompt:
                \(sdi.negativePrompt)
                
                Scheduler:
                \(sdi.scheduler)
                
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
                Text(info)
                    .textSelection(.enabled)
            }
        }
        else {
            Text("No info")
        }
    }
}

struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        var image = SDImage()
        image.prompt = "Test prompt"
        image.negativePrompt = "Test negative prompt"
        image.scheduler = "Test scheduler"
        image.seed = 123
        image.steps = 50
        image.guidanceScale = 7.5
        image.imageIndex = 0
        image.model = "Sample model"
        return InspectorView(image: .constant(image))
    }
}

