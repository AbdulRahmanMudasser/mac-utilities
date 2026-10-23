import Foundation

@MainActor
protocol KeepAwakeTimerFinishedNotifying: AnyObject {
    func notificationSessionStarted()
    func notifyTimerFinished(_ event: KeepAwakeTimerFinishedEvent)
}

extension KeepAwakeTimerFinishedNotifying {
    func notificationSessionStarted() {}
}

nonisolated enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

nonisolated enum NotificationCapabilityState: Equatable, Sendable {
    case off
    case permissionPending
    case authorized
    case denied
    case deliverySurfaceDisabled
    case permissionFailed
    case deliveryFailed
}

nonisolated enum NotificationRecoveryAction: Equatable, Sendable {
    case openSettings
}

nonisolated struct NotificationAuthorizationState: Equatable, Sendable {
    let status: NotificationAuthorizationStatus
    let alertsEnabled: Bool
    let soundsEnabled: Bool
    let notificationCenterEnabled: Bool

    init(status: NotificationAuthorizationStatus,
         alertsEnabled: Bool,
         soundsEnabled: Bool,
         notificationCenterEnabled: Bool = false) {
        self.status = status
        self.alertsEnabled = alertsEnabled
        self.soundsEnabled = soundsEnabled
        self.notificationCenterEnabled = notificationCenterEnabled
    }

    static let notDetermined = Self(status: .notDetermined, alertsEnabled: false, soundsEnabled: false,
                                    notificationCenterEnabled: false)

    var canDeliver: Bool {
        status == .authorized && hasDeliverySurface
    }

    var hasDeliverySurface: Bool {
        alertsEnabled || notificationCenterEnabled
    }

    var valueText: String {
        switch status {
        case .notDetermined: "Permission Not Requested"
        case .denied: "Notifications Denied"
        case .authorized where !hasDeliverySurface: "Delivery Surfaces Disabled"
        case .authorized where !alertsEnabled && notificationCenterEnabled && !soundsEnabled: "Notification Center Only, Sound Off"
        case .authorized where !alertsEnabled && notificationCenterEnabled: "Notification Center Only"
        case .authorized where alertsEnabled && !notificationCenterEnabled && !soundsEnabled: "Alerts Only, Sound Off"
        case .authorized where alertsEnabled && !notificationCenterEnabled: "Alerts Only"
        case .authorized where !soundsEnabled: "Authorized Without Sound"
        case .authorized: "Authorized"
        }
    }
}

nonisolated struct KeepAwakeTimerFinishedEvent: Equatable, Sendable {
    let sessionGeneration: UInt64
    let duration: KeepAwakeDuration

    var durationMinutes: Int? {
        guard case let .timed(minutes) = duration else { return nil }
        return minutes
    }

    var notificationDuration: String? {
        switch duration {
        case let .timed(minutes) where minutes % 60 == 0:
            let hours = minutes / 60
            return String(hours) + "-hour"
        case let .timed(minutes):
            return String(minutes) + "-minute"
        case .untilStopped:
            return nil
        }
    }
}

nonisolated struct LocalNotificationPayload: Equatable, Sendable {
    let identifier: UUID
    let sessionGeneration: UInt64
    let durationMinutes: Int
    let title: String
    let body: String
    let includeSound: Bool
}

nonisolated enum LocalNotificationError: Error, Equatable, LocalizedError, Sendable {
    case authorizationFailed(String)
    case authorizationDenied
    case alertsDisabled
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(message):
            "Notification permission could not be requested. " + message
        case .authorizationDenied:
            "Notifications are denied in System Settings."
        case .alertsDisabled:
            "Notification alerts are disabled in System Settings."
        case let .deliveryFailed(message):
            "The notification could not be delivered. " + message
        }
    }
}
