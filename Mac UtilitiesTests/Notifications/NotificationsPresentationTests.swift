import AppKit
import SwiftUI
import Testing
import UserNotifications
@testable import Mac_Utilities

@MainActor
private final class PresentationNotificationClient: LocalNotificationClient {
    var state = NotificationAuthorizationState.notDetermined
    weak var delegate: UNUserNotificationCenterDelegate?

    func authorizationState() async -> NotificationAuthorizationState { state }
    func requestAuthorization() async throws -> Bool { false }
    func deliver(_ payload: LocalNotificationPayload) async throws {}
    func openNotificationSettings() {}
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) { self.delegate = delegate }
    func shutdown() { delegate = nil }
}

@Suite(.serialized)
@MainActor
struct NotificationsPresentationTests {
    @Test func notificationsViewKeepsSharedBoundsAcrossSupportedSizesAndAppearances() async throws {
        let suiteName = "MacUtilities.NotificationsPresentationTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let client = PresentationNotificationClient()
        let controller = NotificationsController(client: client, preferences: preferences)
        defer { controller.shutdown() }
        let host = NSHostingView(rootView: NotificationsView().environmentObject(controller))

        let states: [(NotificationAuthorizationState, Bool, NotificationCapabilityState)] = [
            (.notDetermined, false, .off),
            (.notDetermined, false, .permissionFailed),
            (.notDetermined, true, .permissionPending),
            (NotificationAuthorizationState(
                status: .denied,
                alertsEnabled: false,
                soundsEnabled: false,
                notificationCenterEnabled: false
            ), false, .denied),
            (NotificationAuthorizationState(
                status: .authorized,
                alertsEnabled: true,
                soundsEnabled: true,
                notificationCenterEnabled: true
            ), true, .deliveryFailed),
        ]

        for (state, enabled, capability) in states {
            controller.showPreviewCapabilityState(state, enabled: enabled, capability: capability)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                host.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 620, height: 420), NSSize(width: 860, height: 660), NSSize(width: 1100, height: 800)] {
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                    #expect(host.bounds.size == size)
                }
            }
        }
    }

    @Test func notificationCopyUsesTheUserFacingTimerLanguage() {
        #expect(KeepAwakeTimerFinishedEvent(sessionGeneration: 1, duration: .timed(minutes: 30)).notificationDuration == "30-minute")
        #expect(KeepAwakeTimerFinishedEvent(sessionGeneration: 2, duration: .timed(minutes: 60)).notificationDuration == "1-hour")
        #expect(KeepAwakeTimerFinishedEvent(sessionGeneration: 3, duration: .timed(minutes: 90)).notificationDuration == "90-minute")
        #expect(KeepAwakeTimerFinishedEvent(sessionGeneration: 4, duration: .untilStopped).notificationDuration == nil)
    }

    @Test func capabilityDetailsAppearOnlyForFailuresWithExistingExplanations() {
        let suiteName = "MacUtilities.NotificationsCapabilityPresentation.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = NotificationsController(client: PresentationNotificationClient(), preferences: preferences)
        defer { controller.shutdown() }

        for capability in [NotificationCapabilityState.off, .permissionPending, .authorized, .denied, .deliverySurfaceDisabled] {
            controller.showPreviewCapabilityState(.notDetermined, enabled: false, capability: capability)
            #expect(controller.capabilityMessage.title == controller.statusText)
            #expect(controller.capabilityMessage.detail == nil)
        }
        controller.showPreviewCapabilityState(.notDetermined, enabled: false, capability: .permissionFailed)
        #expect(controller.capabilityMessage.detail == nil)
        controller.showPreviewCapabilityState(.notDetermined, enabled: true, capability: .deliveryFailed)
        #expect(controller.capabilityMessage.detail == nil)
    }

    @Test func recoveryPreviewsExposeTheRealActionsWithoutPlatformDelivery() {
        let suiteName = "MacUtilities.NotificationsRecoveryPresentation.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let client = PresentationNotificationClient()
        let controller = NotificationsController(client: client, preferences: preferences)
        defer { controller.shutdown() }

        controller.showPreviewCapabilityState(.notDetermined, enabled: true, capability: .permissionPending)
        #expect(controller.isRequestingAuthorization)
        #expect(controller.permissionActionTitle == nil)

        controller.showPreviewCapabilityState(.notDetermined, enabled: false, capability: .permissionFailed)
        #expect(!controller.isRequestingAuthorization)
        #expect(controller.permissionActionTitle == "Try Again")

        controller.showPreviewCapabilityState(
            .init(status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true),
            enabled: true, capability: .deliveryFailed
        )
        #expect(controller.canRetryDelivery)
        #expect(controller.recoveryAction == .openSettings)

        controller.showPreviewCapabilityState(.notDetermined, enabled: false, capability: .off)
        #expect(!controller.canRetryDelivery)
        #expect(controller.permissionActionTitle == "Allow Notifications")
    }
}
