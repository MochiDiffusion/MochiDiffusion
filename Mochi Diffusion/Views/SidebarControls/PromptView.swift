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

    @EnvironmentObject private var generator: ImageGenerator

    private let tokenLimit = 75

    private var estimatedTokens: Int {
        let whitespaceCount = text.components(separatedBy: .whitespacesAndNewlines).count - 1
        let charactersOnly = text.count - whitespaceCount
        let punctuationCount = text.components(separatedBy: .punctuationCharacters).count - 1
        /// A helpful rule of thumb is that one token generally corresponds to ~4 characters of text for common English text.
        /// Source: https://beta.openai.com/tokenizer
        let averageTokenCount = (charactersOnly / 4) + punctuationCount
        return averageTokenCount
    }

    private var tokens: Int {
        guard let tokenizer = generator.tokenizer else {
            return estimatedTokens
        }
        return tokenizer.countTokens(text)
    }

    private var tooManyTokens: Bool {
        tokens > tokenLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(height: height)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)

            HStack(spacing: 0) {
                if tooManyTokens {
                    Text(
                        "Description is too long",
                        comment: "Message warning the user that the prompt (or negative prompt) is too long and part of it may get cut off"
                    )
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .systemYellow))
                }

                Spacer()

                if !text.isEmpty {
                    Text(verbatim: "\(tokens) / \(tokenLimit)")
                        .foregroundColor(tooManyTokens ? Color(nsColor: .systemYellow) : .secondary)
                        .padding([.trailing, .bottom], 2)
                        .font(.caption)
                }
            }
        }
    }
}

struct PromptView: View {
    @EnvironmentObject private var controller: ImageController
    @EnvironmentObject private var generator: ImageGenerator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Include in Image:", systemImage: "text.bubble")
            PromptTextEditor(text: $controller.prompt, height: 120)

            Label("Exclude from Image:", systemImage: "exclamationmark.bubble")
            PromptTextEditor(text: $controller.negativePrompt, height: 70)

            Spacer().frame(height: 2)

            HStack {
                Toggle(isOn: $controller.upscaleGeneratedImages) {
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

                if case .running = generator.state {
                    Button {
                        Task { await ImageGenerator.shared.stopGenerate() }
                    } label: {
                        Text("Stop Generation")
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await ImageController.shared.generate() }
                    } label: {
                        Text(
                            "Generate",
                            comment: "Button to generate image"
                        )
                    }
                    .disabled(ImageController.shared.modelName.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }
}

struct PromptView_Previews: PreviewProvider {
    static var previews: some View {
        PromptView()
            .environmentObject(ImageController.shared)
            .environmentObject(ImageGenerator.shared)
    }
}
