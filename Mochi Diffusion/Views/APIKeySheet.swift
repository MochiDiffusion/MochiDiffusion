//
//  APIKeySheet.swift
//  Mochi Diffusion
//

import SwiftUI

/// Where a hosted engine's API key is entered.
///
/// A sheet rather than a field in Settings, because a key is not a preference: it
/// is a credential for a remote account, and the service is the only authority on
/// whether it works. Settings reports the state of that account; this is the one
/// place a key is typed and the one place it is checked, so a mistyped key fails
/// next to the field that caused it instead of at generation time.
struct APIKeySheet: View {
    let check: OpenAICredentialCheck
    /// Stores the key. Throwing, so a keychain failure is reported while the sheet
    /// is still open rather than after it has closed and taken the text with it.
    let store: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var phase = Phase.editing
    @FocusState private var isFieldFocused: Bool

    /// How far the entered key has got towards being stored.
    private enum Phase: Equatable {
        case editing
        case checking
        /// The service refused it. Nothing to force: a rejected key cannot work.
        case rejected
        /// No verdict, and why. The primary action becomes "Add Anyway", because
        /// someone who cannot reach the service must still be able to store a key.
        case unverified(String)
        /// The keychain write failed, which is not a problem with the key.
        case notStored(String)
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "OpenAI API Key",
                comment: "Title of the sheet where an API key is entered"
            )
            .font(.headline)

            Text(
                "Mochi Diffusion sends your prompts to OpenAI with this key, and OpenAI bills your account for the images.",
                comment: "Explains what an API key will be used for"
            )
            .helpTextFormat()
            .fixedSize(horizontal: false, vertical: true)

            SecureField(
                "",
                text: $key,
                prompt: Text(
                    "sk-…",
                    comment: "Placeholder showing the shape of an OpenAI API key"
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($isFieldFocused)
            .onSubmit(submit)
            // Locked while a check runs, so a verdict can never arrive about text
            // the field no longer contains and store the wrong key.
            .disabled(phase == .checking)

            status

            HStack {
                Link(destination: Self.keyPageURL) {
                    Text(
                        "Get a Key",
                        comment: "Link to the page where an OpenAI API key is created"
                    )
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel", comment: "Button dismissing the API key sheet")
                }
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    primaryLabel
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedKey.isEmpty || phase == .checking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFieldFocused = true }
        // Any edit invalidates the verdict on the previous text, so the message
        // goes rather than sitting under a key it was never about.
        .onChange(of: key) {
            if phase != .checking { phase = .editing }
        }
    }

    private static let keyPageURL = URL(string: "https://platform.openai.com/api-keys")!

    /// "Add Anyway" only after a check that could not reach the service, where it
    /// names what is actually happening: the key goes in unverified.
    @ViewBuilder
    private var primaryLabel: some View {
        if case .unverified = phase {
            Text(
                "Add Anyway",
                comment: "Stores an API key the service could not be asked about"
            )
        } else {
            Text("Add", comment: "Button storing an entered API key")
        }
    }

    /// Always present, so the sheet does not jump as a check starts and finishes.
    @ViewBuilder
    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch phase {
            case .editing:
                // Reserves the row's height without claiming anything.
                Text(verbatim: " ")
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text(
                    "Checking with OpenAI…",
                    comment: "Shown while an entered API key is being verified"
                )
            case .rejected:
                badge("exclamationmark.octagon.fill", .red)
                Text(
                    "OpenAI rejected this key.",
                    comment: "Shown when the service refuses an entered API key"
                )
            case .unverified(let reason):
                badge("exclamationmark.triangle.fill", .orange)
                Text(
                    "Couldn't check this key: \(reason)",
                    comment: "Shown when an API key could not be verified with the service"
                )
            case .notStored(let reason):
                badge("exclamationmark.triangle.fill", .orange)
                Text(
                    "Couldn't save this key: \(reason)",
                    comment: "Shown when writing an API key to the keychain fails"
                )
            }

            Spacer()
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
    }

    private func submit() {
        let candidate = trimmedKey
        guard !candidate.isEmpty else { return }

        // A second press on "Add Anyway" is the user accepting an unchecked key,
        // so it stores rather than asking again. Any edit resets the phase, so
        // this can only ever apply to the text that was checked.
        if case .unverified = phase {
            finish(with: candidate)
            return
        }

        phase = .checking
        Task {
            switch await check.check(candidate) {
            case .valid:
                finish(with: candidate)
            case .rejected:
                phase = .rejected
            case .unreachable(let reason):
                phase = .unverified(reason)
            }
        }
    }

    private func finish(with candidate: String) {
        do {
            try store(candidate)
            dismiss()
        } catch {
            phase = .notStored(error.localizedDescription)
        }
    }
}
