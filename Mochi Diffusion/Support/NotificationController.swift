//
//  NotificationProvider.swift
//  Mochi Diffusion
//
//  Created by Jonathan Mendoza on 13/12/2023.
//

import Foundation
import SwiftUI
import UserNotifications

/// Singleton class to manage all UNUserNotificationCenter interactions
class NotificationController: ObservableObject {
    static let shared = NotificationController()
    @Published var authStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("SendNotification") var sendNotification = true
    @AppStorage("NotificationSound") var notificationSound = true

    private let notificationCenter = UNUserNotificationCenter.current()
    private static let queueEmptyNotificationId = "queueEmpty"

    /// Triggers the prompt to request the user to allow the app to send local notifications
    func requestForNotificationAuthorization() {
        notificationCenter.getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                self.notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        print("Error requesting notification authorization: \(error)")
                        return
                    }
                    Task {
                        await self.fetchAuthStatus()
                    }
                    if !granted { print("User declined authorization prompt") }
                }
            }
        }
    }

    /// Fetches current UserNotificationAuthorization status from UserNotificationCenter
    /// There does not seem to be a nice way to directly observe that property
    /// So we just fetch the current value as required and "cache" it in this
    /// class's property `authStatus`
    func fetchAuthStatus() async -> UNAuthorizationStatus {
        let settings = await self.notificationCenter.notificationSettings()
        Task { @MainActor in
            self.authStatus = settings.authorizationStatus
        }
        return settings.authorizationStatus
    }

    func sendQueueEmptyNotification() async {
        // if the user has notifications turned on in our app's settings window,
        // we still need to fetch the latest authorization status
        // from UserNotificationCenter in case they turned it off there
        var currentAuthStatus: UNAuthorizationStatus?
        if sendNotification {
            currentAuthStatus = await fetchAuthStatus()
        }
        guard sendNotification, currentAuthStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Mochi Diffusion"
        content.body = "Your images are ready!"
        content.sound = notificationSound ? .default : nil
        try? await notificationCenter.add(.init(identifier: NotificationController.queueEmptyNotificationId, content: content, trigger: nil))
    }
}
