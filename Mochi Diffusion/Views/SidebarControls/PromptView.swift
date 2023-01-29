//
//  PromptView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/22.
//

import SwiftUI

struct PromptTextEditor: View {
    @Binding var text: String
    var height: CGFloat
    var tooManyTokens: Bool {
        let whitespaceCount = text.components(separatedBy: .whitespacesAndNewlines).count - 1
        let charactersOnly = text.count - whitespaceCount
        let punctuationCount = text.components(separatedBy: .punctuationCharacters).count - 1
        /// A helpful rule of thumb is that one token generally corresponds to ~4 characters of text for common English text.
        /// Source: https://beta.openai.com/tokenizer
        let averageTokenCount = (charactersOnly / 4) + punctuationCount
        return averageTokenCount > 75
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(height: height)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)

            if tooManyTokens {
                Text(
                    "Description is too long",
                    comment: "Message warning the user that the prompt (or negative prompt) is too long and part of it may get cut off"
                )
                .font(.caption)
                .foregroundColor(Color(nsColor: .systemYellow))
            }
        }
    }
}

struct PromptView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Include in Image:", systemImage: "text.bubble")
            PromptTextEditor(text: $genStore.prompt, height: 103)

            Spacer().frame(height: 6)

            Label("Exclude from Image:", systemImage: "exclamationmark.bubble")
            PromptTextEditor(text: $genStore.negativePrompt, height: 52)

            Spacer().frame(height: 2)

            HStack {
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

                if case .running = $genStore.status.wrappedValue {
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

struct PromptView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        PromptView()
            .environmentObject(genStore)
    }
}
