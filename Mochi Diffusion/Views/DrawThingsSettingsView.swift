//
//  DrawThingsSettingsView.swift
//  Mochi Diffusion
//

import SwiftUI

/// The Draw Things row in General settings: a switch, the status of Mochi's last
/// contact with the server, and the Details sheet that edits the connection.
struct DrawThingsSettingsView: View {
    @Environment(GenerationController.self) private var controller
    @State private var showsDetails = false

    var body: some View {
        let connection = controller.engineSettings.drawThings
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
                    if connection.isActive {
                        DrawThingsStatusView(
                            status: controller.drawThingsStatus,
                            serverName: Self.serverName(connection)
                        )
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
            }
            .padding(4)
        }
        .sheet(isPresented: $showsDetails) {
            DrawThingsDetailsView()
        }
    }

    /// Switching on contacts the saved server; switching off removes its models
    /// without contacting it.
    private var enabled: Binding<Bool> {
        Binding {
            controller.engineSettings.drawThings.enabled
        } set: { enabled in
            controller.engineSettings.drawThings.enabled = enabled
            Task { await controller.loadModels(from: [.connection]) }
        }
    }

    /// The host, with the port only when it is not Draw Things' default.
    static func serverName(_ connection: DrawThingsConnection) -> String {
        connection.port == DrawThingsConnection.defaultPort
            ? connection.host : "\(connection.host):\(connection.port)"
    }
}

/// The status lines under the Draw Things switch, each with its icon in one column
/// so the text lines up.
private struct DrawThingsStatusView: View {
    let status: DrawThingsStatus
    let serverName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .inactive:
                EmptyView()
            case .connecting:
                line {
                    ProgressView()
                        .controlSize(.mini)
                } text: {
                    Text(
                        "Connecting to \(serverName)…",
                        comment: "Draw Things status while Mochi contacts the server"
                    )
                }
            case .connected(let warning):
                line {
                    StatusDot(color: .green)
                } text: {
                    Text(
                        "Connected to \(serverName)",
                        comment: "Draw Things status after the server last answered"
                    )
                }
                if let warning {
                    line {
                        StatusDot(color: .yellow)
                    } text: {
                        Text(verbatim: warning)
                    }
                }
            case .notConnected(let reason):
                line {
                    StatusDot(color: .red)
                } text: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "Not connected to \(serverName)",
                            comment: "Draw Things status after the server could not be reached"
                        )
                        Text(verbatim: reason)
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func line(
        @ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon()
                // Centred on the first line's lowercase letters rather than sitting
                // on its baseline.
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
                .frame(width: 14, alignment: .leading)
            text()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
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
