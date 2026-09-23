//
//  PromptView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/18/22.
//

import SwiftUI

struct PromptTextEditor: View {
    /// The gap between the editor and its token counter, and the height the
    /// counter row keeps whether or not it has anything to show. Reserving it
    /// stops the first typed character from pushing the rest of the sidebar down,
    /// and lets `PromptView` predict this view's height.
    static let counterSpacing: CGFloat = 3
    /// A caption line plus the count's own bottom padding, rounded up: the row has
    /// to be at least as tall as its tallest content or it would still grow by a
    /// point or two when the count appears.
    static let counterHeight: CGFloat = 16

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
        VStack(alignment: .leading, spacing: Self.counterSpacing) {
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
            // `minHeight`, not a fixed height: an over-long warning is free to
            // wrap in a locale where it does not fit on one line rather than
            // being clipped.
            .frame(minHeight: Self.counterHeight, alignment: .top)
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
    /// Measured from the "Include in Image" label, which is always present and
    /// styled identically to the one that is not, so the reclaimed height below
    /// follows the label's real size instead of a guess that font or locale
    /// changes would invalidate.
    @State private var labelHeight: CGFloat = 0

    private static let spacing: CGFloat = 6
    private static let includeHeight: CGFloat = 120
    private static let excludeHeight: CGFloat = 70

    /// The prompt block keeps one height whichever model is selected, so nothing
    /// below it moves when the negative prompt comes and goes — the Engine picker
    /// sitting directly underneath used to jump out from under the pointer that
    /// had just changed it.
    ///
    /// The space goes to the remaining editor rather than being left blank, which
    /// suits the models that lack a negative prompt: FLUX.2 Klein attends to 512
    /// prompt tokens where Core ML SD attends to 75.
    private var includeEditorHeight: CGFloat {
        if controller.currentConstraints.supportsNegativePrompt {
            return Self.includeHeight
        }
        // The label, the editor, its token counter, and the two gaps the pair of
        // them occupies in the enclosing stack.
        return Self.includeHeight + labelHeight + Self.excludeHeight
            + PromptTextEditor.counterSpacing + PromptTextEditor.counterHeight
            + Self.spacing * 2
    }

    private func updatePromptTokenInfo(for model: (any EngineModel)?) {
        tokenLimit = model?.constraints.promptTokenLimit
        tokenizer = Tokenizer(modelDir: model?.tokenizerModelDir)
    }

    var body: some View {
        @Bindable var configStore = configStore
        @Bindable var focusCon = focusCon

        VStack(alignment: .leading, spacing: Self.spacing) {
            Text("Include in Image")
                .sidebarLabelFormat()
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    labelHeight = $0
                }
            PromptTextEditor(
                text: $configStore.prompt,
                height: includeEditorHeight,
                focusBinding: $focusCon.promptFieldIsFocused,
                tokenizer: tokenizer,
                tokenLimit: tokenLimit
            )

            // A distilled model has no classifier-free guidance, so there is
            // nothing for a negative prompt to steer away from. The field used to
            // be offered and the text silently discarded.
            if controller.currentConstraints.supportsNegativePrompt {
                Text("Exclude from Image")
                    .sidebarLabelFormat()
                PromptTextEditor(
                    text: $configStore.negativePrompt,
                    height: Self.excludeHeight,
                    focusBinding: $focusCon.negativePromptFieldIsFocused,
                    tokenizer: tokenizer,
                    tokenLimit: tokenLimit
                )
            }

            Button {
                Task { await controller.generate() }
            } label: {
                if !controller.hasGenerationWork {
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
            // The live selection. The persisted global value may survive a
            // temporarily unavailable models folder while this becomes nil.
            .disabled(controller.currentModelId == nil)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .onChange(of: controller.currentModel?.id, initial: true) { _, _ in
            updatePromptTokenInfo(for: controller.currentModel)
        }
    }
}
