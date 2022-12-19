//
//  InspectorView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI
import StableDiffusion

struct InspectorView: View {
    var image: Binding<SDImage?>
    var copyToPrompt: () -> ()
    
    var body: some View {
        if let sdi = image.wrappedValue {
            let info = getHumanReadableInfo(sdi: sdi)
            
            VStack {
                VStack(alignment: .leading) {
                    Text(info)
                        .textSelection(.enabled)
                        .frame(maxWidth: 300)
                }
                
                Spacer().frame(height: 12)
                
                HStack(alignment: .center) {
                    Button("Copy to Prompt") {
                        copyToPrompt()
                    }
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.declareTypes([.string], owner: nil)
                        pb.setString(info, forType: .string)
                    }
                }
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
        image.width = 512
        image.height = 512
        image.scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
        image.seed = 123
        image.steps = 50
        image.guidanceScale = 7.5
        image.imageIndex = 0
        image.model = "Sample model"
        return InspectorView(image: .constant(image), copyToPrompt: {})
    }
}

