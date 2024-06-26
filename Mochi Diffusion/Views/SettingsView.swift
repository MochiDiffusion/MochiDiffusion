//
//  SettingsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import CoreML
import StableDiffusion
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var controller: ImageController
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
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Autosave & Restore Images")

                        Spacer()

                        Toggle("", isOn: $controller.autosaveImages)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    HStack {
                        TextField("", text: $controller.imageDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!$controller.autosaveImages.wrappedValue)

                        Button {
                            guard let url = showOpenPanel(from: URL(string: controller.imageDir))
                            else { return }
                            controller.imageDir = url.path(percentEncoded: false)
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

                    Picker("", selection: $controller.imageType) {
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
                        TextField("", text: $controller.modelDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard let url = showOpenPanel(from: URL(string: controller.modelDir))
                            else { return }
                            controller.modelDir = url.path(percentEncoded: false)
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
                    Text("ControlNet Folder")

                    HStack {
                        TextField("", text: $controller.controlNetDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard
                                let url = showOpenPanel(from: URL(string: controller.controlNetDir))
                            else { return }
                            controller.controlNetDir = url.path(percentEncoded: false)
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

                        Toggle("", isOn: $controller.useTrash)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Text(
                        "If option is turned off, removed images are permanently deleted. Applies to imported and autosaved images.",
                        comment: "Help text for Move Images to Trash setting"
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

                        Toggle("", isOn: $controller.reduceMemory)
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
        }
    }

    @ViewBuilder
    private var imageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Show Image Preview")

                        Spacer()

                        Toggle("", isOn: $controller.showGenerationPreview)
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

                    Picker("", selection: $controller.scheduler) {
                        ForEach(Scheduler.allCases, id: \.self) { scheduler in
                            Text(scheduler.rawValue).tag(scheduler)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(4)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ML Compute Unit")

                        Spacer()

                        Picker("", selection: $controller.mlComputeUnitPreference) {
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

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Filter Inappropriate Images")

                        Spacer()

                        Toggle("", isOn: $controller.safetyChecker)
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
        }
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
        .environmentObject(ImageController.shared)
}
