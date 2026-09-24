//
//  NotificationProvider.swift
//  Mochi Diffusion
//
//  Created by Jonathan Mendoza on 13/12/2023.
//

import SwiftUI
import UserNotifications

@MainActor
@Observable public final class NotificationController {
    static let shared = NotificationController()
    var authStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored
    @AppStorage("SendNotification") private var _sendNotification = true
    @ObservationIgnored
    var sendNotification: Bool {
        get {
            access(keyPath: \.sendNotification)
            return _sendNotification
        }
        set {
            withMutation(keyPath: \.sendNotification) {
                _sendNotification = newValue
            }
        }
    }

    @ObservationIgnored
    @AppStorage("PlayNotificationSound") private var _playNotificationSound = true
    @ObservationIgnored
    var playNotificationSound: Bool {
        get {
            access(keyPath: \.playNotificationSound)
            return _playNotificationSound
        }
        set {
            withMutation(keyPath: \.playNotificationSound) {
                _playNotificationSound = newValue
            }
        }
    }

    private let notificationCenter = UNUserNotificationCenter.current()
    private static let queueEmptyNotificationId = "queueEmpty"

    /// Triggers the prompt to request the user to allow the app to send local notifications
    func requestForNotificationAuthorization() {
        notificationCenter.getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [
                        .alert,
                        .sound,
                        .badge,
                    ]
                ) { granted, error in
                    if let error = error {
                        print("Error requesting notification authorization: \(error)")
                        return
                    }
                    Task { @MainActor in
                        await NotificationController.shared.fetchAuthStatus()
                    }
                    if !granted { print("User declined authorization prompt") }
                }
            }
        }
    }

    /// Fetches the current authorization status and caches it in `authStatus`.
    ///
    /// `UNUserNotificationCenter` offers no way to observe the status, so it is
    /// fetched when needed.
    func fetchAuthStatus() async -> UNAuthorizationStatus {
        let settings = await self.notificationCenter.notificationSettings()
        self.authStatus = settings.authorizationStatus
        return settings.authorizationStatus
    }

    func sendImagesReadyNotification(count: Int) async {
        // Notifications enabled in Settings may still have been turned off in
        // System Settings, so fetch the latest authorization status.
        var currentAuthStatus: UNAuthorizationStatus?
        if sendNotification {
            currentAuthStatus = await fetchAuthStatus()
        }
        guard sendNotification, currentAuthStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Mochi Diffusion"
        content.body =
            count == 1
            ? String(localized: "1 image saved.") : String(localized: "\(count) images saved.")
        content.sound = playNotificationSound ? .default : nil
        try? await notificationCenter.add(
            .init(
                identifier: NotificationController.queueEmptyNotificationId, content: content,
                trigger: nil))
    }
}
