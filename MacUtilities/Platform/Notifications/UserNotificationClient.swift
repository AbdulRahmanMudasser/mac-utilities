import AppKit
import Foundation
import UserNotifications

@MainActor
protocol LocalNotificationClient: AnyObject {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func deliver(_ payload: LocalNotificationPayload) async throws
    func openNotificationSettings()
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
    func shutdown()
}

@MainActor
final class UserNotificationClient: LocalNotificationClient {
    private let center: UNUserNotificationCenter

    private let openURL: (URL) -> Bool
    private let applicationBundleIdentifier: String

    init(center: UNUserNotificationCenter = .current(),
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         applicationBundleIdentifier: String = "com.abdulrahman.mac-utilities") {
        self.center = center
        self.openURL = openURL
        self.applicationBundleIdentifier = applicationBundleIdentifier
    }

    func authorizationState() async -> NotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.state(for: settings))
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { continuation.resume(throwing: LocalNotificationError.authorizationFailed(error.localizedDescription)) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func deliver(_ payload: LocalNotificationPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = Self.userInfo(for: payload)
        if payload.includeSound { content.sound = .default }

        let request = UNNotificationRequest(identifier: Self.requestIdentifier(for: payload),
                                             content: content,
                                             trigger: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: LocalNotificationError.deliveryFailed(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func openNotificationSettings() {
        let notificationsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(applicationBundleIdentifier)")
        if let notificationsURL, openURL(notificationsURL) { return }
        _ = openURL(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        center.delegate = delegate
    }

    func shutdown() {
        center.delegate = nil
    }

    nonisolated static func requestIdentifier(for payload: LocalNotificationPayload) -> String {
        "keep-awake-\(payload.sessionGeneration)-\(payload.identifier.uuidString)"
    }

    nonisolated static func userInfo(for payload: LocalNotificationPayload) -> [AnyHashable: Any] {
        [
            "eventID": payload.identifier.uuidString,
            "sessionGeneration": payload.sessionGeneration,
            "durationMinutes": payload.durationMinutes,
        ]
    }

    private nonisolated static func state(for settings: UNNotificationSettings) -> NotificationAuthorizationState {
        let status: NotificationAuthorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            status = .notDetermined
        case .denied:
            status = .denied
        case .authorized, .provisional, .ephemeral:
            status = .authorized
        @unknown default:
            status = .denied
        }
        return NotificationAuthorizationState(
            status: status,
            alertsEnabled: settings.alertSetting == .enabled,
            soundsEnabled: settings.soundSetting == .enabled,
            notificationCenterEnabled: settings.notificationCenterSetting == .enabled
        )
    }
}
