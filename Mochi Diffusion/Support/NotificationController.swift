//
//  NotificationProvider.swift
//  Mochi Diffusion
//
//  Created by Jonathan Mendoza on 13/12/2023.
//

import Foundation
import UserNotifications

enum NotificationService {
    nonisolated private static let queueEmptyNotificationID = "queueEmpty"
    nonisolated private static let sendNotificationKey = "SendNotification"
    nonisolated private static let playNotificationSoundKey = "PlayNotificationSound"

    nonisolated private static func bool(
        forKey key: String,
        default defaultValue: Bool
    ) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    nonisolated private static var sendNotification: Bool {
        bool(forKey: sendNotificationKey, default: true)
    }

    nonisolated private static var playNotificationSound: Bool {
        bool(forKey: playNotificationSoundKey, default: true)
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestAuthorizationIfNeeded() async {
        let notificationCenter = UNUserNotificationCenter.current()
        let currentStatus = await currentAuthorizationStatus()
        guard currentStatus != .authorized else { return }
        _ = try? await notificationCenter.requestAuthorization(
            options: [
                .alert,
                .sound,
                .badge,
            ]
        )
    }

    static func sendQueueEmptyNotification() async {
        guard sendNotification else { return }
        guard await currentAuthorizationStatus() == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Mochi Diffusion"
        content.body = String(localized: "Your images are ready!")
        content.sound = playNotificationSound ? .default : nil
        try? await UNUserNotificationCenter.current().add(
            .init(
                identifier: queueEmptyNotificationID,
                content: content,
                trigger: nil))
    }
}
