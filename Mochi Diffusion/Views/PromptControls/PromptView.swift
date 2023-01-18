//
//  PromptView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/22.
//

import SwiftUI

struct PromptView: View {
    @EnvironmentObject var genStore: GeneratorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Include in Image:",
                comment: "Label for prompt text field"
            )
            TextEditor(text: $genStore.prompt)
                .font(.system(size: 14))
                .frame(height: 85)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)

            Spacer().frame(height: 6)

            Text(
                "Exclude from Image:",
                comment: "Label for negative prompt text field"
            )
            TextEditor(text: $genStore.negativePrompt)
                .font(.system(size: 14))
                .frame(height: 52)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)

            Spacer().frame(height: 2)

            HStack(alignment: .center) {
                Toggle(isOn: $genStore.upscaleGeneratedImages) {
                    Label {
                        Text(
                            "HD",
                            comment: "Label for toggle to auto convert generated images to high resolution"
                        )
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .help("Convert all images to High Resolution (this will use more memory)")

                Spacer()

                if case .running = genStore.status {
                    Button(action: genStore.stopGeneration) {
                        Text("Stop Generation")
                    }
                    .controlSize(.large)
                } else {
                    Button(action: genStore.generate) {
                        Text(
                            "Generate",
                            comment: "Button to generate image"
                        )
                    }
                    .disabled($genStore.currentModel.wrappedValue.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }
}
