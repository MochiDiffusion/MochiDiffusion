//
//  DrawThingsSettingsView.swift
//  Mochi Diffusion
//

import SwiftUI

struct DrawThingsSettingsView: View {
    @Environment(GenerationController.self) private var controller
    @State private var connection = DrawThingsConnection()
    @State private var port = "7859"
    @State private var sharedSecret = ""
    @State private var removeSecret = false
    @State private var hasStoredSecret = false
    @State private var status: String?
    @State private var connecting = false
    private let secrets = KeychainSecretStore()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Draw Things (Prototype)", isOn: $connection.enabled)
                Text(
                    "Run Draw Things on this Mac or a computer on your network. Enable its gRPC server and Model Browsing."
                )
                .helpTextFormat()
                HStack {
                    TextField("Host", text: $connection.host)
                    TextField("Port", text: $port).frame(width: 65)
                }
                .textFieldStyle(.roundedBorder)
                Toggle("Use TLS (match the server)", isOn: $connection.useTLS)
                Text(
                    "TLS supports Draw Things’ self-signed certificate. This prototype does not verify the server’s identity; use a trusted local network."
                )
                .helpTextFormat()
                SecureField(
                    hasStoredSecret
                        ? "Shared secret saved — leave blank to keep" : "Shared secret (optional)",
                    text: $sharedSecret
                )
                .textFieldStyle(.roundedBorder)
                if hasStoredSecret {
                    Toggle("Remove saved shared secret", isOn: $removeSecret)
                }
                HStack {
                    Button(connection.enabled ? "Save & Connect" : "Save") {
                        Task { await connect() }
                    }
                    .disabled(connecting)
                    if connecting { ProgressView().controlSize(.small) }
                }
                if let status {
                    Text(verbatim: status).font(.caption).textSelection(.enabled)
                }
                Text(
                    "Generates one still image using model defaults. Image inputs, advanced options, video, cloud and automatic server discovery are not included."
                )
                .helpTextFormat()
            }
            .padding(4)
            .disabled(connecting)
        }
        .onAppear {
            connection = controller.engineSettings.drawThings
            port = String(connection.port)
            refreshSecretState()
        }
        .onChange(of: connection) { _, _ in
            sharedSecret = ""
            removeSecret = false
            refreshSecretState()
        }
        .onChange(of: port) { _, _ in
            sharedSecret = ""
            removeSecret = false
            refreshSecretState()
        }
    }

    private func refreshSecretState() {
        var value = connection
        value.port = Int(port) ?? 0
        hasStoredSecret =
            (try? value.validated()).map { secrets.hasSecret(for: $0.secretAccount) } ?? false
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            var value = connection
            value.port = Int(port) ?? 0
            value = try value.validated()
            if removeSecret {
                try secrets.setSecret(nil, for: value.secretAccount)
            } else if !sharedSecret.isEmpty {
                try secrets.setSecret(sharedSecret, for: value.secretAccount)
            }
            controller.engineSettings.drawThings = value
            sharedSecret = ""
            removeSecret = false
            refreshSecretState()
            await controller.loadModels()
            if !value.enabled {
                status = "Draw Things is disabled."
            } else if controller.hasModels(.drawThings) {
                controller.selectEngine(.drawThings)
                status = "Connected. Choose a model in the sidebar, enter a prompt, and Generate."
            } else {
                status =
                    controller.discoveryMessage
                    ?? "No models available. Check the host, port, TLS, shared secret and Model Browsing setting."
            }
        } catch {
            status = error.localizedDescription
        }
    }
}
