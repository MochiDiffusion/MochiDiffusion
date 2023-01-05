//
//  PromptView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/22.
//

import SwiftUI

struct PromptView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Include in Image:",
                 tableName: "Prompt",
                 comment: "Label for Include in Image text field")
            TextEditor(text: $store.prompt)
                .font(.system(size: 14))
                .frame(height: 85)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)
                
            Spacer().frame(height: 6)
            
            Text("Exclude from Image:",
                 tableName: "Prompt",
                 comment: "Label for Exclude from Image text field")
            TextEditor(text: $store.negativePrompt)
                .font(.system(size: 14))
                .frame(height: 52)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)
            
            Spacer().frame(height: 2)
            
            HStack(alignment: .center) {
                Toggle(isOn: $store.upscaleGeneratedImages) {
                    Label("HD", systemImage: "wand.and.stars")
                }
                .help("Convert all images to High Resolution (this will use more memory)")
                
                Spacer()
                
                Button("Generate") {
                    store.generate()
                }
                .disabled($store.currentModel.wrappedValue.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
