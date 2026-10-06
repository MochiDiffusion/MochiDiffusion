//
//  DrawThingsSettingsView.swift
//  Mochi Diffusion
//

import SwiftUI

/// The Draw Things row in General settings: a switch, the server with its Details
/// sheet, and the result of the last model-list fetch with a refresh button.
struct DrawThingsSettingsView: View {
    @Environment(GenerationController.self) private var controller
    @State private var showsDetails = false

    /// "today at 8:41 PM", in the middle of a sentence.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()

    var body: some View {
        let connection = controller.engineSettings.drawThings
        let status = controller.drawThingsStatus
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Draw Things")
                    Spacer()
                    Toggle("", isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Divider()
                HStack(spacing: 12) {
                    if connection.host.isEmpty {
                        Text("No server", comment: "Draw Things row when no host has been entered")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: connection.serverName)
                    }
                    Spacer(minLength: 0)
                    Button {
                        showsDetails = true
                    } label: {
                        Text(
                            "Details…",
                            comment: "Button that opens the Draw Things connection settings"
                        )
                    }
                    .disabled(!connection.enabled)
                }
                if connection.isActive {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            modelCount(status)
                            refreshButton(isFetching: status.isFetching)
                        }
                        message(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        }
        .sheet(isPresented: $showsDetails) {
            DrawThingsDetailsView()
        }
    }

    /// Switching on fetches the saved server's models; switching off removes them
    /// without contacting it.
    private var enabled: Binding<Bool> {
        Binding {
            controller.engineSettings.drawThings.enabled
        } set: { enabled in
            controller.engineSettings.drawThings.enabled = enabled
            Task { await controller.loadModels(from: [.connection]) }
        }
    }

    /// How many models the last fetch gave the picker. Before the first fetch from
    /// this server finishes, there is no count yet.
    @ViewBuilder
    private func modelCount(_ status: DrawThingsStatus) -> some View {
        switch status.lastFetch {
        case nil:
            Text(
                "Updating model list…",
                comment: "Draw Things status while Mochi fetches the model list"
            )
        case .models(let count, _):
            countText(count)
        case .noModels, .failed:
            countText(0)
        }
    }

    private func countText(_ count: Int) -> Text {
        Text(
            "^[\(count) model](inflect: true)",
            comment: "How many Draw Things models the last fetch gave the model picker"
        )
    }

    /// A spinner in the button's place while the list is being fetched.
    @ViewBuilder
    private func refreshButton(isFetching: Bool) -> some View {
        if isFetching {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        } else {
            Button {
                Task { await controller.loadModels(from: [.connection]) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .frame(width: 16, height: 16)
            .help(
                String(
                    localized: "Refresh Model List",
                    comment: "Help for the button that fetches the Draw Things model list again"
                ))
        }
    }

    /// The last fetch, under the count. Before the first fetch finishes, the count's
    /// line already says the list is updating.
    @ViewBuilder
    private func message(_ status: DrawThingsStatus) -> some View {
        if status.isFetching, status.lastFetch != nil {
            Text(
                "Updating model list…",
                comment: "Draw Things status while Mochi fetches the model list"
            )
        } else {
            switch status.lastFetch {
            case nil:
                EmptyView()
            case .models(_, let date):
                updated(date)
            case .noModels(let reason, let date):
                VStack(alignment: .leading, spacing: 4) {
                    updated(date)
                    Text(verbatim: reason)
                }
            case .failed(let reason, let date):
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Couldn’t update model list \(Self.dateFormatter.string(from: date))",
                        comment: "When Mochi last failed to fetch the Draw Things model list"
                    )
                    Text(verbatim: reason)
                }
            }
        }
    }

    private func updated(_ date: Date) -> Text {
        Text(
            "Updated model list \(Self.dateFormatter.string(from: date))",
            comment: "When the Draw Things model list was last fetched"
        )
    }
}

/// Edits the server's connection. OK saves and reconnects, even when nothing
/// changed; Cancel discards the edits.
struct DrawThingsDetailsView: View {
    @Environment(GenerationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var useTLS = true
    @State private var sharedSecret = ""
    @State private var saveError: String?
    private let secrets = KeychainSecretStore()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(text: $host, prompt: Text(verbatim: "studio.local")) {
                        Text("Host", comment: "Draw Things server host name field label")
                    }
                    TextField(text: $port) {
                        Text("Port", comment: "Draw Things server port field label")
                    }
                } header: {
                    Text(
                        "In Draw Things, turn on the gRPC API server and Model Browsing.",
                        comment: "Draw Things connection settings instructions"
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                } footer: {
                    Text(
                        "Use localhost for Draw Things on this Mac, or the hostname of a machine on the local network, such as studio.local",
                        comment: "Help text for the Draw Things host field"
                    )
                    .helpTextFormat()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Toggle(isOn: $useTLS) {
                        Text("Use TLS", comment: "Draw Things server TLS toggle label")
                    }
                    SecureField(
                        text: $sharedSecret,
                        prompt: Text("Optional", comment: "Shared secret field placeholder")
                    ) {
                        Text(
                            "Shared Secret", comment: "Draw Things server shared secret field label"
                        )
                    }
                } footer: {
                    Text(
                        "Match the server’s settings in Draw Things. TLS encrypts the connection but doesn’t verify the server’s identity, so use a trusted network.",
                        comment: "Help text for the Draw Things TLS and shared secret settings"
                    )
                    .helpTextFormat()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let saveError {
                    Text(verbatim: saveError)
                        .helpTextFormat()
                        .textSelection(.enabled)
                }
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Text("OK")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .onAppear {
            let connection = controller.engineSettings.drawThings
            host = connection.host
            port = String(connection.port)
            useTLS = connection.useTLS
            sharedSecret = secrets.secret(for: DrawThingsConnection.secretAccount) ?? ""
        }
        .onChange(of: host) { _, newValue in
            host = DrawThingsConnection.filteredHost(newValue)
        }
        .onChange(of: port) { _, newValue in
            port = DrawThingsConnection.filteredPort(newValue)
        }
    }

    private func save() {
        do {
            try secrets.setSecret(sharedSecret, for: DrawThingsConnection.secretAccount)
        } catch {
            saveError = String(
                localized: "Couldn’t save the shared secret in the Keychain.",
                comment: "Shown when the Draw Things shared secret cannot be saved"
            )
            return
        }
        var connection = controller.engineSettings.drawThings
        connection.host = host
        // An empty or out-of-range port is not rejected here: the connection fails
        // and Settings shows why.
        connection.port = Int(port) ?? 0
        connection.useTLS = useTLS
        controller.engineSettings.drawThings = connection
        Task { await controller.loadModels(from: [.connection]) }
        dismiss()
    }
}
