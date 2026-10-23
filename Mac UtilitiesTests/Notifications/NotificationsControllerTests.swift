import Foundation
import AppKit
import UserNotifications
import Testing
@testable import Mac_Utilities

@MainActor
private final class FakeLocalNotificationClient: LocalNotificationClient {
    var state: NotificationAuthorizationState
    var requestResult: Result<Bool, Error> = .success(true)
    var deliveryError: Error?
    var suspendsAuthorizationRequest = false
    var suspendsDelivery = false
    private(set) var requestCount = 0
    private(set) var deliveryAttempts: [LocalNotificationPayload] = []
    private(set) var deliveryPayloads: [LocalNotificationPayload] = []
    private(set) var shutdownCount = 0
    private(set) var openSettingsCount = 0
    weak var delegate: UNUserNotificationCenterDelegate?
    private var authorizationContinuation: CheckedContinuation<Bool, Error>?
    private var deliveryContinuation: CheckedContinuation<Void, Error>?

    init(state: NotificationAuthorizationState) {
        self.state = state
    }

    func authorizationState() async -> NotificationAuthorizationState { state }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        let granted: Bool
        if suspendsAuthorizationRequest {
            granted = try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
            }
        } else {
            granted = try requestResult.get()
        }
        if granted {
            state = NotificationAuthorizationState(status: .authorized, alertsEnabled: true, soundsEnabled: true,
                                                   notificationCenterEnabled: true)
        } else {
            state = NotificationAuthorizationState(status: .denied, alertsEnabled: false, soundsEnabled: false)
        }
        return granted
    }

    func deliver(_ payload: LocalNotificationPayload) async throws {
        deliveryAttempts.append(payload)
        if suspendsDelivery {
            try await withCheckedThrowingContinuation { continuation in
                deliveryContinuation = continuation
            }
        }
        if let deliveryError { throw deliveryError }
        deliveryPayloads.append(payload)
    }

    func completeAuthorizationRequest(_ result: Result<Bool, Error>) {
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume(with: result)
    }

    func completeDelivery(_ result: Result<Void, Error>) {
        let continuation = deliveryContinuation
        deliveryContinuation = nil
        continuation?.resume(with: result)
    }

    func openNotificationSettings() {
        openSettingsCount += 1
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        self.delegate = delegate
    }

    func shutdown() {
        shutdownCount += 1
        delegate = nil
    }
}

@MainActor
private final class NotificationTestHarness {
    let suiteName = "MacUtilities.NotificationsTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let client: FakeLocalNotificationClient
    let controller: NotificationsController

    init(state: NotificationAuthorizationState = .notDetermined) {
        preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        client = FakeLocalNotificationClient(state: state)
        controller = NotificationsController(client: client, preferences: preferences)
    }

    func cleanUp() {
        controller.shutdown()
        preferences.removePersistentDomain(forName: suiteName)
    }
}

@Suite(.serialized)
@MainActor
struct NotificationsControllerTests {
    @Test func notificationsAreOffByDefaultAndPersistOnlyTheOptInPreference() {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }

        #expect(!harness.controller.isEnabled)
        #expect(harness.preferences.object(forKey: NotificationsController.enabledPreferenceKey) == nil)
        #expect(harness.preferences.object(forKey: NotificationsController.legacyKeepAwakeTimerPreferenceKey) == nil)
        #expect(harness.controller.authorizationValue == "Permission Not Requested")
    }

    @Test func releasedKeepAwakePreferenceMigratesOnceToTheGlobalMasterSwitch() {
        let suiteName = "MacUtilities.NotificationsMigrationTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        preferences.set(true, forKey: NotificationsController.legacyKeepAwakeTimerPreferenceKey)
        let controller = NotificationsController(preferences: preferences)
        defer {
            controller.shutdown()
            preferences.removePersistentDomain(forName: suiteName)
        }

        #expect(controller.isEnabled)
        #expect(preferences.bool(forKey: NotificationsController.enabledPreferenceKey))
        #expect(preferences.object(forKey: NotificationsController.legacyKeepAwakeTimerPreferenceKey) == nil)
    }

    @Test func enablingAuthorizedNotificationsPersistsTheOptInWithoutRequestingAgain() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }

        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        #expect(harness.controller.isEnabled)
        #expect(harness.preferences.bool(forKey: NotificationsController.enabledPreferenceKey))
        #expect(harness.client.requestCount == 0)
        #expect(harness.controller.errorMessage == nil)
    }

    @Test func enablingDeniedNotificationsTurnsTheOptInBackOff() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .denied, alertsEnabled: false, soundsEnabled: false, notificationCenterEnabled: false
        ))
        defer { harness.cleanUp() }

        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        #expect(!harness.controller.isEnabled)
        #expect(!harness.preferences.bool(forKey: NotificationsController.enabledPreferenceKey))
        #expect(harness.controller.capabilityState == .denied)
        #expect(harness.controller.statusDetail == "Notifications are denied in System Settings.")
        #expect(harness.controller.recoveryAction == .openSettings)
        #expect(harness.controller.authorizationValue == "Notifications Denied")
    }

    @Test func externallyDisabledAlertsRemainVisibleAsAnHonestPermissionState() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: false, soundsEnabled: false, notificationCenterEnabled: false
        ))
        defer { harness.cleanUp() }

        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        #expect(!harness.controller.isEnabled)
        #expect(harness.controller.capabilityState == .deliverySurfaceDisabled)
        #expect(harness.controller.authorizationValue == "Delivery Surfaces Disabled")
        #expect(harness.controller.statusDetail == "Notifications are disabled in System Settings.")
        #expect(harness.controller.recoveryAction == .openSettings)
    }

    @Test func disabledAlertsRemainDeliverableThroughNotificationCenter() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: false, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }

        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        #expect(harness.controller.isEnabled)
        #expect(harness.controller.capabilityState == .authorized)
        #expect(harness.controller.authorizationValue == "Notification Center Only")
        #expect(harness.controller.statusDetail == "Alerts are disabled; notifications remain in Notification Center.")
        #expect(harness.controller.recoveryAction == .openSettings)
    }

    @Test func appActivationRefreshesAnExternallyChangedAuthorizationState() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.client.state = NotificationAuthorizationState(
            status: .authorized, alertsEnabled: false, soundsEnabled: true, notificationCenterEnabled: false
        )

        await harness.controller.refreshAuthorization()

        #expect(!harness.controller.isEnabled)
        #expect(harness.controller.capabilityState == .deliverySurfaceDisabled)
        #expect(harness.controller.authorizationValue == "Delivery Surfaces Disabled")
    }

    @Test func notDeterminedPermissionIsRequestedOnlyWhenTheUserEnablesTheFeature() async {
        let harness = NotificationTestHarness()
        defer { harness.cleanUp() }

        #expect(harness.client.requestCount == 0)
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        #expect(harness.client.requestCount == 1)
        #expect(harness.controller.isEnabled)
        #expect(harness.controller.authorizationState.canDeliver)
    }

    @Test func staleAuthorizationFailureCannotOverwriteAUserDisable() async {
        let harness = NotificationTestHarness()
        defer { harness.cleanUp() }
        harness.client.suspendsAuthorizationRequest = true

        harness.controller.setEnabled(true)
        for _ in 0..<20 where harness.client.requestCount == 0 { await Task.yield() }
        #expect(harness.client.requestCount == 1)

        harness.controller.setEnabled(false)
        harness.client.completeAuthorizationRequest(.failure(LocalNotificationError.deliveryFailed("stale")))
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isEnabled)
        #expect(harness.controller.capabilityState == .off)
        #expect(harness.controller.errorMessage == nil)
        #expect(!harness.preferences.bool(forKey: NotificationsController.enabledPreferenceKey))
    }

    @Test func completedFiniteSessionDeliversOneNotificationWithNoPrivateData() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: false, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        let event = KeepAwakeTimerFinishedEvent(sessionGeneration: 17, duration: .timed(minutes: 60))
        harness.controller.notifyTimerFinished(event)
        harness.controller.notifyTimerFinished(event)
        harness.controller.notifyTimerFinished(KeepAwakeTimerFinishedEvent(sessionGeneration: 16, duration: .timed(minutes: 30)))
        for _ in 0..<20 { await Task.yield() }

        let payload = try! #require(harness.client.deliveryPayloads.first)
        #expect(harness.client.deliveryPayloads.count == 1)
        #expect(payload.sessionGeneration == 17)
        #expect(payload.durationMinutes == 60)
        #expect(payload.title == "Keep Awake Finished")
        #expect(payload.body == "1-hour session has ended.")
        #expect(!payload.includeSound)
        #expect(!payload.body.contains("GB"))
    }

    @Test func staleDeliveryFailureCannotReplaceTheUserSelectedOffState() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.client.suspendsDelivery = true

        harness.controller.notifyTimerFinished(
            KeepAwakeTimerFinishedEvent(sessionGeneration: 18, duration: .timed(minutes: 30))
        )
        for _ in 0..<20 where harness.client.deliveryAttempts.isEmpty { await Task.yield() }
        #expect(harness.client.deliveryAttempts.count == 1)

        harness.controller.setEnabled(false)
        harness.client.completeDelivery(.failure(LocalNotificationError.deliveryFailed("stale")))
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isEnabled)
        #expect(harness.controller.capabilityState == .off)
        #expect(harness.controller.errorMessage == nil)
    }

    @Test func untilStoppedAndDisabledSessionsNeverDeliver() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }

        harness.controller.notifyTimerFinished(KeepAwakeTimerFinishedEvent(sessionGeneration: 1, duration: .untilStopped))
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.controller.setEnabled(false)
        harness.controller.notifyTimerFinished(KeepAwakeTimerFinishedEvent(sessionGeneration: 2, duration: .timed(minutes: 30)))
        for _ in 0..<20 { await Task.yield() }

        #expect(harness.client.deliveryPayloads.isEmpty)
    }

    @Test func failedDeliveryIsRecordedAndNotRetriedForTheSameSession() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .authorized, alertsEnabled: true, soundsEnabled: true, notificationCenterEnabled: true
        ))
        defer { harness.cleanUp() }
        harness.client.deliveryError = LocalNotificationError.deliveryFailed("fixture")
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()

        let event = KeepAwakeTimerFinishedEvent(sessionGeneration: 22, duration: .timed(minutes: 30))
        harness.controller.notifyTimerFinished(event)
        harness.controller.notifyTimerFinished(event)
        for _ in 0..<20 { await Task.yield() }

        #expect(harness.client.deliveryPayloads.isEmpty)
        #expect(harness.controller.capabilityState == .deliveryFailed)
        #expect(harness.controller.statusDetail == "The notification could not be delivered. fixture")
        #expect(harness.controller.capabilityMessage == UtilityCapabilityMessage(
            title: "Notification Delivery Failed",
            detail: "The notification could not be delivered. fixture"
        ))
    }

    @Test func deniedStateOpensSystemSettingsThroughTheInjectedClient() async {
        let harness = NotificationTestHarness(state: NotificationAuthorizationState(
            status: .denied, alertsEnabled: false, soundsEnabled: false, notificationCenterEnabled: false
        ))
        defer { harness.cleanUp() }

        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.controller.openNotificationSettings()

        #expect(harness.client.openSettingsCount == 1)
    }

    @Test func platformSettingsOpenerPrefersTheNotificationsPaneAndFallsBackOnlyWhenNeeded() {
        var openedURLs: [URL] = []
        let client = UserNotificationClient(openURL: { url in
            openedURLs.append(url)
            return true
        }, applicationBundleIdentifier: "com.abdulrahman.mac-utilities")
        defer { client.shutdown() }

        client.openNotificationSettings()

        #expect(openedURLs.count == 1)
        #expect(openedURLs.first?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.abdulrahman.mac-utilities")
    }

    @Test func platformSettingsOpenerFallsBackToSystemSettingsWhenTheDeepLinkFails() {
        var openedURLs: [URL] = []
        let client = UserNotificationClient(openURL: { url in
            openedURLs.append(url)
            return false
        }, applicationBundleIdentifier: "com.abdulrahman.mac-utilities")
        defer { client.shutdown() }

        client.openNotificationSettings()

        #expect(openedURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.abdulrahman.mac-utilities",
            "file:///System/Applications/System%20Settings.app/",
        ])
    }

    @Test func foregroundPresentationAlwaysIncludesNativeBannerAndList() {
        let harness = NotificationTestHarness()
        defer { harness.cleanUp() }

        let options = NotificationsController.foregroundPresentationOptions(includesSound: false)
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
    }

    @Test func eligibleForegroundPresentationIncludesNotificationCenterAndConfiguredSound() {
        let silent = NotificationsController.foregroundPresentationOptions(includesSound: false)
        #expect(silent.contains(.banner))
        #expect(silent.contains(.list))
        #expect(!silent.contains(.sound))

        let audible = NotificationsController.foregroundPresentationOptions(includesSound: true)
        #expect(audible.contains(.banner))
        #expect(audible.contains(.list))
        #expect(audible.contains(.sound))
    }

    @Test func platformPayloadCarriesGenerationDurationAndUniqueEventIdentity() {
        let eventID = UUID()
        let payload = LocalNotificationPayload(
            identifier: eventID,
            sessionGeneration: 42,
            durationMinutes: 120,
            title: "Keep Awake Finished",
            body: "2-hour session has ended.",
            includeSound: true
        )

        #expect(UserNotificationClient.requestIdentifier(for: payload) == "keep-awake-42-\(eventID.uuidString)")
        let userInfo = UserNotificationClient.userInfo(for: payload)
        #expect(userInfo["eventID"] as? String == eventID.uuidString)
        #expect(userInfo["sessionGeneration"] as? UInt64 == 42)
        #expect(userInfo["durationMinutes"] as? Int == 120)
    }
    @Test func permissionFailureCanBeRetriedWithoutConcurrentPrompts() async {
        let harness = NotificationTestHarness()
        defer { harness.cleanUp() }
        harness.client.requestResult = .failure(LocalNotificationError.deliveryFailed("permission fixture"))
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        #expect(harness.controller.capabilityState == .permissionFailed)
        #expect(harness.controller.permissionActionTitle == "Try Again")
        #expect(harness.controller.capabilityMessage == UtilityCapabilityMessage(
            title: "Notification Permission Request Failed",
            detail: "The notification could not be delivered. permission fixture"
        ))
        await harness.controller.refreshAuthorization()
        #expect(harness.controller.capabilityState == .permissionFailed)
        harness.client.requestResult = .success(true)
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        #expect(harness.controller.isEnabled)
        #expect(harness.client.requestCount == 2)
    }

    @Test func manualRetryPreservesIdentityAndSurvivesRefresh() async {
        let harness = NotificationTestHarness(state: .init(status: .authorized, alertsEnabled: true, soundsEnabled: true))
        defer { harness.cleanUp() }
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.client.deliveryError = LocalNotificationError.deliveryFailed("fixture")
        harness.controller.notifyTimerFinished(.init(sessionGeneration: 1, duration: .timed(minutes: 1)))
        for _ in 0..<30 { await Task.yield() }
        #expect(harness.controller.canRetryDelivery)
        await harness.controller.refreshAuthorization()
        #expect(harness.controller.capabilityState == .deliveryFailed)
        harness.client.deliveryError = nil
        harness.controller.retryDelivery()
        harness.controller.retryDelivery()
        for _ in 0..<30 { await Task.yield() }
        #expect(harness.client.deliveryAttempts.count == 2)
        #expect(harness.client.deliveryAttempts.first?.identifier == harness.client.deliveryAttempts.last?.identifier)
        #expect(!harness.controller.canRetryDelivery)
        #expect(harness.controller.capabilityState == .authorized)
    }

    @Test func newerSessionAndExpiryInvalidateRetries() async {
        let suite = "NotificationsRetryExpiry.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = FakeLocalNotificationClient(state: .init(status: .authorized, alertsEnabled: true, soundsEnabled: false))
        var time: TimeInterval = 0
        let controller = NotificationsController(client: client, preferences: preferences, now: { time })
        defer { controller.shutdown() }
        controller.setEnabled(true)
        await controller.waitForAuthorizationTask()
        client.deliveryError = LocalNotificationError.deliveryFailed("fixture")
        controller.notifyTimerFinished(.init(sessionGeneration: 1, duration: .timed(minutes: 1)))
        for _ in 0..<30 { await Task.yield() }
        #expect(controller.canRetryDelivery)
        time = 301
        controller.retryDelivery()
        #expect(!controller.canRetryDelivery)
        #expect(client.deliveryAttempts.count == 1)
        controller.notificationSessionStarted()
        #expect(!controller.hasFailedDelivery)
    }

    @Test func permissionPromptCannotOverlapWhenDisabledAndReenabled() async {
        let harness = NotificationTestHarness()
        defer { harness.cleanUp() }
        harness.client.suspendsAuthorizationRequest = true
        harness.controller.setEnabled(true)
        for _ in 0..<30 { await Task.yield() }
        harness.controller.setEnabled(false)
        harness.controller.setEnabled(true)
        #expect(harness.client.requestCount == 1)
        harness.client.completeAuthorizationRequest(.success(true))
        for _ in 0..<30 { await Task.yield() }
        #expect(!harness.controller.isEnabled)
    }

    @Test func savedOptInCanRequestPermissionWhenAuthorizationIsUndetermined() async {
        let suiteName = "MacUtilities.SavedNotificationOptIn.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: NotificationsController.enabledPreferenceKey)
        let client = FakeLocalNotificationClient(state: .notDetermined)
        let controller = NotificationsController(client: client, preferences: preferences)
        defer { controller.shutdown() }

        #expect(controller.isEnabled)
        #expect(controller.permissionActionTitle == "Allow Notifications")
        controller.setEnabled(true)
        await controller.waitForAuthorizationTask()
        #expect(client.requestCount == 1)
        #expect(controller.capabilityState == .authorized)
    }

    @Test func disablingDuringManualRetryDiscardsLateFailure() async {
        let harness = NotificationTestHarness(state: .init(status: .authorized, alertsEnabled: true, soundsEnabled: true))
        defer { harness.cleanUp() }
        harness.controller.setEnabled(true)
        await harness.controller.waitForAuthorizationTask()
        harness.client.deliveryError = LocalNotificationError.deliveryFailed("fixture")
        harness.controller.notifyTimerFinished(.init(sessionGeneration: 1, duration: .timed(minutes: 1)))
        for _ in 0..<30 { await Task.yield() }
        harness.client.suspendsDelivery = true
        harness.controller.retryDelivery()
        for _ in 0..<30 { await Task.yield() }
        harness.controller.setEnabled(false)
        harness.client.completeDelivery(.failure(LocalNotificationError.deliveryFailed("late")))
        for _ in 0..<30 { await Task.yield() }
        #expect(harness.controller.capabilityState == .off)
        #expect(!harness.controller.hasFailedDelivery)
        #expect(!harness.controller.isDelivering)
    }

}
