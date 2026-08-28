//
//  SettingsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import CoreML
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    /// Held here rather than injected: this is the only view that writes a
    /// credential, and the store is a stateless handle to the keychain.
    private let secrets = KeychainSecretStore()
    private let logger = Logger()
    /// Never the key itself once saved — only what the user is currently typing.
    @State private var apiKey = ""
    /// Presence, asked via `hasSecret` so the pane never reads the secret.
    @State private var hasStoredAPIKey = false
    /// Needed because the scheduler is a per-model option shown in a
    /// model-agnostic window: without the selected model's constraints, this could
    /// offer a scheduler the model overrides.
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(NotificationController.self) private var notificationController:
        NotificationController

    var body: some View {
        VStack(spacing: 16) {
            TabView {
                generalView
                    .tabItem {
                        Label {
                            Text(
                                "General",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "gearshape")
                        }
                    }
                imageView
                    .tabItem {
                        Label {
                            Text(
                                "Image",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "photo")
                        }
                    }
                enginesView
                    .tabItem {
                        Label {
                            Text(
                                "Engines",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "cpu")
                        }
                    }
                notificationsView
                    .tabItem {
                        Label {
                            Text(
                                "Notifications",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "bell.badge")
                        }
                    }
            }
        }
        .padding()
        .frame(width: 450, alignment: .top)
        .fixedSize()
    }

    @ViewBuilder
    private var generalView: some View {
        @Bindable var configStore = configStore

        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    Text("Images Folder")

                    HStack {
                        TextField("", text: $configStore.imageDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard
                                let url = showOpenPanel(from: URL(string: configStore.imageDir))
                            else { return }
                            configStore.imageDir = url.path(percentEncoded: false)
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(Color.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Open in Finder")
                    }
                }
                .padding(4)

                Divider()

                HStack {
                    Text("Image Type")

                    Spacer()

                    Picker("", selection: $configStore.imageType) {
                        Text(verbatim: "PNG")
                            .tag(UTType.png.preferredFilenameExtension!)
                        Text(verbatim: "JPEG")
                            .tag(UTType.jpeg.preferredFilenameExtension!)
                        Text(verbatim: "HEIC")
                            .tag(UTType.heic.preferredFilenameExtension!)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Model Folder")

                    HStack {
                        TextField("", text: $configStore.modelDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard
                                let url = showOpenPanel(from: URL(string: configStore.modelDir))
                            else { return }
                            configStore.modelDir = url.path(percentEncoded: false)
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(Color.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Open in Finder")
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Move Images to Trash")

                        Spacer()

                        Toggle("", isOn: $configStore.useTrash)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Text(
                        "If option is turned off, removed images are permanently deleted. Applies to imported and generated images.",
                        comment: "Help text for Move Images to Trash setting"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

        }
    }

    @ViewBuilder
    private var imageView: some View {
        @Bindable var configStore = configStore

        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Show Image Preview")

                        Spacer()

                        Toggle("", isOn: $configStore.showGenerationPreview)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Text(
                        "Show the image as its being generated.",
                        comment: "Help text for Show Image Preview setting"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

            GroupBox {
                HStack {
                    Text("Scheduler")

                    Spacer()

                    // A distilled model pins its scheduler, so a picker here would
                    // display one value while every generation used another. Pinned
                    // is shown disabled at the value that will be used, matching
                    // how the sidebar treats a pinned step count.
                    let scheduler = controller.currentConstraints.scheduler
                    if let pinned = scheduler.pinnedOption {
                        Text(pinned.displayName)
                            .foregroundStyle(.secondary)
                            .help(
                                String(
                                    localized:
                                        "The selected model always uses this scheduler.",
                                    comment:
                                        "Explains why the scheduler cannot be changed"
                                )
                            )
                    } else {
                        Picker("", selection: $configStore.scheduler) {
                            ForEach(scheduler.options, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(4)
            }

        }
    }

    /// Settings that belong to one engine rather than to the app.
    ///
    /// `ControlNetDir`, `ReduceMemory`, `MLComputeUnitPreference` and
    /// `SafetyChecker` used to sit in General and Image, presented as global while
    /// only ever affecting Core ML Stable Diffusion. Iris ignores all four, so a
    /// user changing them saw no effect and no reason why.
    ///
    /// The safety checker is a `StableDiffusionPipeline` module, which is why it
    /// belongs here rather than being a model capability: nothing outside Core ML
    /// has one to enable.
    ///
    /// The models folder stays global: one shared folder is a settled decision, so
    /// there is no per-engine path to show here.
    @ViewBuilder
    private var enginesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(controller.engines) { engine in
                Text(verbatim: engine.displayName)
                    .font(.headline)
                settings(for: engine.id)
            }
        }
    }

    /// One engine's settings.
    ///
    /// A `switch` rather than something the engine itself supplies: a settings pane
    /// is a view, and `GenerationEngineDescriptor` is deliberately free of SwiftUI.
    /// An engine with nothing to configure — Iris today — says so, so its section
    /// does not read as a rendering failure.
    @ViewBuilder
    private func settings(for engine: EngineID) -> some View {
        @Bindable var configStore = configStore

        switch engine {
        case .coreMLStableDiffusion:
            GroupBox {
                VStack(alignment: .leading) {
                    Text("ControlNet Folder")

                    HStack {
                        TextField("", text: $configStore.controlNetDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard
                                let url = showOpenPanel(
                                    from: URL(string: configStore.controlNetDir)
                                )
                            else { return }
                            configStore.controlNetDir = url.path(percentEncoded: false)
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(Color.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Open in Finder")
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Filter Inappropriate Images")

                        Spacer()

                        Toggle("", isOn: $configStore.safetyChecker)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Text(
                        "Uses the model's safety checker module. This does not guarantee that all inappropriate images will be filtered.",
                        comment: "Help text for Filter Inappropriate Images setting"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Reduce Memory Usage")

                        Spacer()

                        Toggle("", isOn: $configStore.reduceMemory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Text(
                        "Reduce memory usage further at the cost of speed.",
                        comment: "Help text for Reduce Memory Usage setting"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ML Compute Unit")

                        Spacer()

                        Picker("", selection: $configStore.mlComputeUnitPreference) {
                            Text(
                                "Auto (Recommended)",
                                comment:
                                    "Option to use the CPU + Neural Engine for split-einsum models, and CPU + GPU for original models"
                            )
                            .tag(ComputeUnitPreference.auto)
                            Text("CPU & Neural Engine")
                                .tag(ComputeUnitPreference.cpuAndNeuralEngine)
                            Text("CPU & GPU")
                                .tag(ComputeUnitPreference.cpuAndGPU)
                            Text(
                                "All",
                                comment:
                                    "Option to use all CPU, GPU, & Neural Engine for compute unit"
                            )
                            .tag(ComputeUnitPreference.all)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    Text(
                        "**Auto** selects the most appropriate configuration for the selected model.",
                        comment: "Explanation for the 'Auto' ML Compute Unit option"
                    )
                    .helpTextFormat()

                    Text(
                        "**CPU & Neural Engine** provides a good balance between speed and low memory usage, but only works with split-einsum models.",
                        comment: "Explanation for the 'CPU & NE' ML Compute Unit option"
                    )
                    .helpTextFormat()

                    Text(
                        "**CPU & GPU** is compatible with all models and may be faster on M1 Max, Ultra and later, but will use more memory.",
                        comment: "Explanation for the 'CPU & GPU' ML Compute Unit option"
                    )
                    .helpTextFormat()

                    Divider()

                    Text(
                        "Manually selecting an incompatible ML Compute Unit may cause poor performance or crash."
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

        case OpenAIImageEngine.id:
            GroupBox {
                VStack(alignment: .leading) {
                    Text("API Key")

                    HStack {
                        // The stored key is never read back into the field. A
                        // credential the UI echoes is one that ends up in a
                        // screenshot, and `hasSecret` answers the only question
                        // this pane needs to ask.
                        SecureField(
                            "",
                            text: $apiKey,
                            prompt: Text(
                                hasStoredAPIKey
                                    ? String(
                                        localized: "A key is stored",
                                        comment: "Placeholder when an API key is already saved")
                                    : String(
                                        localized: "Paste your API key",
                                        comment: "Placeholder when no API key is saved")
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Button {
                            saveAPIKey()
                        } label: {
                            Text("Save", comment: "Button to store an API key")
                        }
                        .disabled(apiKey.isEmpty)

                        if hasStoredAPIKey {
                            Button {
                                removeAPIKey()
                            } label: {
                                Text("Remove", comment: "Button to delete a stored API key")
                            }
                        }
                    }

                    Text(
                        "The key is kept in your keychain. It is never written to image metadata, logs, or saved requests.",
                        comment: "Explains where a hosted engine's API key is stored"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }
            .onAppear { refreshAPIKeyState() }

        default:
            Text(
                "This engine has no settings.",
                comment: "Shown in Settings for an engine with nothing to configure"
            )
            .helpTextFormat()
        }
    }

    // MARK: - API key

    /// Stores the key and asks for a refresh, so the engine picker stops saying a
    /// key is missing without the user having to do anything else.
    private func saveAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try secrets.setSecret(key, for: OpenAIImageEngine.secretAccount)
            apiKey = ""
            refreshAPIKeyState()
            Task { await controller.loadModels() }
        } catch {
            logger.error("Couldn't store the API key: \(error)")
        }
    }

    private func removeAPIKey() {
        do {
            try secrets.setSecret(nil, for: OpenAIImageEngine.secretAccount)
            apiKey = ""
            refreshAPIKeyState()
            Task { await controller.loadModels() }
        } catch {
            logger.error("Couldn't remove the API key: \(error)")
        }
    }

    /// Presence only, never the value.
    private func refreshAPIKeyState() {
        hasStoredAPIKey = secrets.hasSecret(for: OpenAIImageEngine.secretAccount)
    }

    @ViewBuilder
    private var notificationsView: some View {
        @Bindable var notificationController = notificationController

        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Send Notifications")

                        Spacer()

                        Toggle("", isOn: $notificationController.sendNotification)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: notificationController.sendNotification) {
                                if notificationController.sendNotification {
                                    notificationController.requestForNotificationAuthorization()
                                }
                            }
                    }
                    Text(
                        "Send notification when images are ready.",
                        comment: "Help text for Send Notifications setting"
                    )
                    .helpTextFormat()

                    if notificationController.sendNotification,
                        notificationController.authStatus != .authorized
                    {
                        // on iOS there is `openNotificationSettingsURLString` but for macOS,
                        // seems like we need to manually call this here.
                        Link(
                            destination: URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.notifications")!
                        ) {
                            Text(
                                "Allow Mochi Diffusion to send notifications under System Settings."
                            )
                            .multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(4)

                Divider()

                VStack(alignment: .leading) {
                    HStack {
                        Text("Play notification sound")

                        Spacer()

                        Toggle("", isOn: $notificationController.playNotificationSound)
                            .disabled(!notificationController.sendNotification)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                .padding(4)
            }.task {
                _ = await notificationController.fetchAuthStatus()
            }
        }
    }

    private func showOpenPanel(from initialDirectoryURL: URL?) -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = initialDirectoryURL
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        let response = openPanel.runModal()

        guard response == .OK, let url = openPanel.url else {
            return nil
        }

        return url
    }
}

#Preview {
    SettingsView()
        .environment(ConfigStore())
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(NotificationController.shared)
}
