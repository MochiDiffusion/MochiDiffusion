//
//  NotificationProvider.swift
//  Mochi Diffusion
//
//  Created by Jonathan Mendoza on 13/12/2023.
//

import Foundation
import SwiftUI
import UserNotifications

class CustomNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Singleton class to manage all UNUserNotificationCenter interactions
class NotificationController: ObservableObject {
    enum State: Sendable {
        case notification(String), noNotification
    }

    enum SendNotification: String {
        case never, background, always
    }

    enum WhenNotification: String {
        case everyImage, everyTask, allTasks
    }

    static let shared = NotificationController()
    @Published var authStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("SendNotification") var sendNotification: SendNotification = .background
    @AppStorage("WhenNotification") var whenNotification: WhenNotification = .everyImage
    @AppStorage("PlayNotificationSound") var playNotificationSound = true

    private let customNotificationCenterDelegate = CustomNotificationCenterDelegate()
    private let notificationCenter: UNUserNotificationCenter
    private static let queueEmptyNotificationId = "queueEmpty"
    private(set) var state: State = .noNotification

    init() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = customNotificationCenterDelegate
        self.notificationCenter = notificationCenter
    }

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
        let settings = await notificationCenter.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            requestForNotificationAuthorization()
        }
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
        if sendNotification == .always {
            currentAuthStatus = await fetchAuthStatus()
        } else if sendNotification == .background {
            currentAuthStatus = await fetchAuthStatus()
        }
        guard sendNotification != .never, currentAuthStatus == .authorized else { return }
        let isAppActive = await NSApplication.shared.isActive
        let message: String
        if whenNotification == .everyImage {
            message = String(localized: "Your image is ready!", comment: "The message content")
        } else {
            message = String(localized: "Your images are ready!", comment: "The message content")
        }
        // show Notification with MessageBanner()
        if isAppActive && sendNotification == .always {
            state = .notification(message)
            // remove MessageBanner() after 3 Seconds
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 3) {
                self.state = .noNotification
            }
        }
        if (!isAppActive && sendNotification == .background) || sendNotification == .always {
            let content = UNMutableNotificationContent()
            content.title = "Mochi Diffusion"
            content.body = message
            content.sound = playNotificationSound ? .default : nil
            try? await notificationCenter.add(.init(identifier: NotificationController.queueEmptyNotificationId, content: content, trigger: nil))
        }
    }
}
