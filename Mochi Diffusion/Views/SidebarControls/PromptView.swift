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

    @Binding var focusBinding: Bool

    @FocusState private var focused: Bool

    let tokenizer: Tokenizer?
    let tokenLimit: Int?

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
        guard let tokenizer else {
            return estimatedTokens
        }
        return tokenizer.countTokens(text)
    }

    private var tooManyTokens: Bool {
        guard let tokenLimit else { return false }
        return tokens > tokenLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .focused($focused)
                .syncFocus($focusBinding, with: _focused)
                .frame(height: height)
                .border(Color(nsColor: .gridColor))
                .cornerRadius(4)

            HStack(spacing: 0) {
                if tokenLimit != nil, tooManyTokens {
                    Text(
                        "Description is too long",
                        comment:
                            "Message warning the user that the prompt (or negative prompt) is too long and part of it may get cut off"
                    )
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }

                Spacer()

                if !text.isEmpty {
                    Group {
                        if let tokenLimit {
                            Text(verbatim: "\(tokens) / \(tokenLimit)")
                                .foregroundColor(tooManyTokens ? .accentColor : .secondary)
                        } else {
                            Text(verbatim: "\(tokens)")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding([.trailing, .bottom], 2)
                    .font(.caption)
                }
            }
        }
    }
}

struct PromptView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @Environment(FocusController.self) private var focusCon: FocusController
    @Environment(GenerationState.self) private var generationState: GenerationState
    @State private var tokenizer: Tokenizer?
    @State private var tokenLimit: Int?

    private func updatePromptTokenInfo(for model: (any MochiModel)?) {
        tokenLimit = model?.promptTokenLimit
        tokenizer = Tokenizer(modelDir: model?.tokenizerModelDir)
    }

    var body: some View {
        @Bindable var configStore = configStore
        @Bindable var focusCon = focusCon

        VStack(alignment: .leading, spacing: 6) {
            Text("Include in Image")
                .sidebarLabelFormat()
            PromptTextEditor(
                text: $configStore.prompt,
                height: 120,
                focusBinding: $focusCon.promptFieldIsFocused,
                tokenizer: tokenizer,
                tokenLimit: tokenLimit
            )

            Text("Exclude from Image")
                .sidebarLabelFormat()
            PromptTextEditor(
                text: $configStore.negativePrompt,
                height: 70,
                focusBinding: $focusCon.negativePromptFieldIsFocused,
                tokenizer: tokenizer,
                tokenLimit: tokenLimit
            )

            Spacer().frame(height: 2)

            Button {
                Task { await controller.generate() }
            } label: {
                if case .ready = generationState.state {
                    Text(
                        "Generate",
                        comment: "Button to generate image"
                    )
                } else {
                    Text(
                        "Add to Queue",
                        comment: "Button to generate image"
                    )
                }
            }
            .disabled(configStore.modelId == nil)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .onChange(of: controller.currentModel?.id, initial: true) { _, _ in
            updatePromptTokenInfo(for: controller.currentModel)
        }
    }
}

#Preview {
    PromptView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
        .environment(FocusController())
        .environment(GenerationState.shared)
}
