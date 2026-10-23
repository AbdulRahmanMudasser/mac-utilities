import Combine
import UserNotifications

@MainActor
final class NotificationsController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let enabledPreferenceKey = "notifications.enabled.v1"
    static let legacyKeepAwakeTimerPreferenceKey = "notifications.keepAwakeTimer.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorizationState: NotificationAuthorizationState = .notDetermined
    @Published private(set) var capabilityState: NotificationCapabilityState = .off
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRequestingAuthorization = false

    @Published private(set) var isDelivering = false
    @Published private(set) var hasFailedDelivery = false
    private var failedPayload: LocalNotificationPayload?
    private var failureDeadline: TimeInterval?
    private var retryExpiryTask: Task<Void, Never>?
    private var deliveryEpoch: UInt64 = 0
    private var permissionRequestInFlight = false
    private let now: () -> TimeInterval

    var onKeepAwakeRoute: (@MainActor () -> Void)?

    private let client: any LocalNotificationClient
    private let preferences: UserDefaults
    private var authorizationTask: Task<Void, Never>?
    private var authorizationGeneration: UInt64 = 0
    private var latestAttemptedGeneration: UInt64?
    private var isShowingCapabilityIssue = false
    private var hasShutDown = false

    init(client: (any LocalNotificationClient)? = nil,
         preferences: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.client = client ?? UserNotificationClient()
        self.preferences = preferences
        self.isEnabled = Self.readAndMigratePreference(from: preferences)
        super.init()
        self.client.setDelegate(self)
    }

    var authorizationValue: String {
        authorizationState.valueText
    }

    var statusText: String {
        switch capabilityState {
        case .off: "Notifications Off"
        case .permissionPending: "Waiting For Notification Permission"
        case .authorized: "Notifications Active"
        case .denied: "Notifications Denied In System Settings"
        case .deliverySurfaceDisabled: "Notifications Unavailable"
        case .permissionFailed: "Notification Permission Request Failed"
        case .deliveryFailed: "Notification Delivery Failed"
        }
    }

    var statusDetail: String? {
        switch capabilityState {
        case .off: nil
        case .permissionPending: "Waiting for macOS notification permission."
        case .authorized where !authorizationState.alertsEnabled && authorizationState.notificationCenterEnabled && !authorizationState.soundsEnabled:
            "Alerts and sound are disabled; notifications remain in Notification Center."
        case .authorized where !authorizationState.alertsEnabled && authorizationState.notificationCenterEnabled:
            "Alerts are disabled; notifications remain in Notification Center."
        case .authorized where authorizationState.alertsEnabled && !authorizationState.notificationCenterEnabled && !authorizationState.soundsEnabled:
            "Notification Center and sound are disabled; desktop alerts remain enabled."
        case .authorized where authorizationState.alertsEnabled && !authorizationState.notificationCenterEnabled:
            "Notification Center is disabled; desktop alerts remain enabled."
        case .authorized where !authorizationState.soundsEnabled: "Sound is disabled in System Settings."
        case .authorized: nil
        case .denied: "Notifications are denied in System Settings."
        case .deliverySurfaceDisabled where !authorizationState.alertsEnabled && !authorizationState.notificationCenterEnabled:
            "Notifications are disabled in System Settings."
        case .deliverySurfaceDisabled where !authorizationState.alertsEnabled:
            "Notification alerts are disabled in System Settings."
        case .deliverySurfaceDisabled:
            "Notification Center delivery is disabled in System Settings."
        case .permissionFailed:
            errorMessage ?? "Notification permission could not be requested."
        case .deliveryFailed:
            errorMessage ?? "The last notification could not be delivered."
        }
    }

    var capabilityMessage: UtilityCapabilityMessage {
        let detail: String?
        switch capabilityState {
        case .permissionFailed, .deliveryFailed:
            detail = errorMessage
        default:
            detail = nil
        }
        return UtilityCapabilityMessage(title: statusText, detail: detail)
    }

    var recoveryAction: NotificationRecoveryAction? {
        switch capabilityState {
        case .denied, .deliverySurfaceDisabled: .openSettings
        case .authorized: .openSettings
        case .off, .deliveryFailed, .permissionFailed:
            authorizationState.status == .authorized ? .openSettings : nil
        case .permissionPending: nil
        }
    }

    var permissionActionTitle: String? {
        guard !isRequestingAuthorization, !permissionRequestInFlight,
              authorizationState.status == .notDetermined else { return nil }
        return capabilityState == .permissionFailed ? "Try Again" : "Allow Notifications"
    }

    var canRetryDelivery: Bool {
        hasFailedDelivery && !isDelivering && isEnabled &&
            failureDeadline.map { now() < $0 } == true
    }

    func notificationSessionStarted() {
        deliveryEpoch &+= 1
        clearFailedDelivery()
        isDelivering = false
        if isEnabled { updateCapability(for: authorizationState) }
    }

    private func clearFailedDelivery() {
        failedPayload = nil
        failureDeadline = nil
        hasFailedDelivery = false
        retryExpiryTask?.cancel()
        retryExpiryTask = nil
    }

    func retryDelivery() {
        guard canRetryDelivery, let payload = failedPayload else { return }
        isDelivering = true
        let epoch = deliveryEpoch
        let generation = authorizationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.client.authorizationState()
            guard self.isCurrentAuthorization(generation), epoch == self.deliveryEpoch else { return }
            guard self.failureDeadline.map({ self.now() < $0 }) == true else {
                self.isDelivering = false
                self.clearFailedDelivery()
                self.updateCapability(for: state)
                return
            }
            guard state.canDeliver else {
                self.isDelivering = false
                self.disablePreferenceForCapabilityIssue(state)
                return
            }
            await self.deliver(payload, state: state, generation: generation, epoch: epoch)
        }
    }

    private func deliver(_ payload: LocalNotificationPayload, state: NotificationAuthorizationState,
                         generation: UInt64, epoch: UInt64) async {
        let originalDeadline = failureDeadline
        do {
            try await client.deliver(payload)
            guard isCurrentAuthorization(generation), epoch == deliveryEpoch else { return }
            isDelivering = false
            clearFailedDelivery()
            updateCapability(for: state)
        } catch {
            guard isCurrentAuthorization(generation), epoch == deliveryEpoch else { return }
            isDelivering = false
            if let originalDeadline, now() >= originalDeadline {
                clearFailedDelivery()
                updateCapability(for: state)
                return
            }
            failedPayload = payload
            failureDeadline = originalDeadline ?? now() + 300
            hasFailedDelivery = true
            capabilityState = .deliveryFailed
            errorMessage = error.localizedDescription
            retryExpiryTask?.cancel()
            let remaining = max(0, (failureDeadline ?? now()) - now())
            retryExpiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard let self, epoch == self.deliveryEpoch else { return }
                self.clearFailedDelivery()
                if !self.isDelivering { self.updateCapability(for: self.authorizationState) }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !hasShutDown, !(enabled && permissionRequestInFlight) else { return }
        guard !enabled || !isEnabled || authorizationState.status == .notDetermined else { return }
        if !enabled {
            deliveryEpoch &+= 1
            clearFailedDelivery()
            isDelivering = false
        }
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        isEnabled = enabled
        isShowingCapabilityIssue = false
        if !enabled {
            isRequestingAuthorization = false
            capabilityState = .off
            errorMessage = nil
        }
        preferences.set(enabled, forKey: Self.enabledPreferenceKey)
        errorMessage = nil
        guard enabled else { return }
        let generation = authorizationGeneration
        authorizationTask = Task { @MainActor [weak self] in
            await self?.enableAndAuthorize(generation: generation)
        }
    }

    func refreshAuthorization() async {
        guard !hasShutDown else { return }
        let generation = authorizationGeneration
        let state = await client.authorizationState()
        guard isCurrentGeneration(generation) else { return }
        authorizationState = state
        if isEnabled {
            if state.status == .denied || (state.status == .authorized && !state.canDeliver) {
                disablePreferenceForCapabilityIssue(state)
            } else if !hasFailedDelivery && !isDelivering {
                updateCapability(for: state)
            }
        } else if capabilityState == .permissionFailed && state.status == .notDetermined {
            authorizationState = state
        } else if isShowingCapabilityIssue,
                  state.status == .denied || (state.status == .authorized && !state.canDeliver) {
            updateCapability(for: state, preservingDisabledIssue: true)
        } else {
            isShowingCapabilityIssue = false
            updateCapability(for: state)
        }
    }

    func waitForAuthorizationTask() async {
        await authorizationTask?.value
    }

    #if DEBUG
    func showPreviewAuthorizationRequest() {
        guard !hasShutDown else { return }
        isEnabled = true
        isRequestingAuthorization = true
        capabilityState = .permissionPending
        errorMessage = nil
    }

    func showPreviewCapabilityState(_ state: NotificationAuthorizationState,
                                    enabled: Bool,
                                    capability: NotificationCapabilityState) {
        guard !hasShutDown else { return }
        clearFailedDelivery()
        isDelivering = false
        isEnabled = enabled
        isRequestingAuthorization = capability == .permissionPending
        authorizationState = state
        capabilityState = capability
        isShowingCapabilityIssue = capability == .denied || capability == .deliverySurfaceDisabled
        errorMessage = nil
        if capability == .deliveryFailed {
            failedPayload = LocalNotificationPayload(
                identifier: UUID(), sessionGeneration: 1, durationMinutes: 30,
                title: "Keep Awake Finished", body: "30-minute session has ended.",
                includeSound: state.soundsEnabled
            )
            failureDeadline = now() + 300
            hasFailedDelivery = true
        }
    }
    #endif

    func notifyTimerFinished(_ event: KeepAwakeTimerFinishedEvent) {
        guard !hasShutDown, isEnabled, event.notificationDuration != nil, event.durationMinutes != nil,
              latestAttemptedGeneration.map({ event.sessionGeneration > $0 }) ?? true else { return }
        notificationSessionStarted()
        latestAttemptedGeneration = event.sessionGeneration
        isDelivering = true
        let epoch = deliveryEpoch
        let generation = authorizationGeneration

        Task { @MainActor [weak self] in
            guard let self, self.isCurrentDelivery(generation, event: event) && epoch == self.deliveryEpoch else { return }
            let state = await self.client.authorizationState()
            guard self.isCurrentDelivery(generation, event: event) && epoch == self.deliveryEpoch else { return }
            self.authorizationState = state
            guard state.canDeliver,
                  let duration = event.notificationDuration,
                  let durationMinutes = event.durationMinutes else {
                self.disablePreferenceForCapabilityIssue(state)
                return
            }
            let payload = LocalNotificationPayload(
                identifier: UUID(),
                sessionGeneration: event.sessionGeneration,
                durationMinutes: durationMinutes,
                title: "Keep Awake Finished",
                body: duration + " session has ended.",
                includeSound: state.soundsEnabled
            )
            await self.deliver(payload, state: state, generation: generation, epoch: epoch)
        }
    }

    func openNotificationSettings() {
        guard !hasShutDown else { return }
        client.openNotificationSettings()
    }

    func shutdown() {
        guard !hasShutDown else { return }
        notificationSessionStarted()
        hasShutDown = true
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        isRequestingAuthorization = false
        client.shutdown()
        onKeepAwakeRoute = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler(Self.foregroundPresentationOptions(
                includesSound: notification.request.content.sound != nil
            ))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self?.onKeepAwakeRoute?()
            }
            completionHandler()
        }
    }

    private func enableAndAuthorize(generation: UInt64) async {
        let initial = await client.authorizationState()
        guard isCurrentAuthorization(generation) else { return }
        updateCapability(for: initial)

        if initial.status == .notDetermined {
            isRequestingAuthorization = true
            capabilityState = .permissionPending
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
            do {
                _ = try await client.requestAuthorization()
                permissionRequestInFlight = false
            } catch {
                permissionRequestInFlight = false
                guard isCurrentAuthorization(generation) else { return }
                isRequestingAuthorization = false
                isEnabled = false
                preferences.set(false, forKey: Self.enabledPreferenceKey)
                capabilityState = .permissionFailed
                isShowingCapabilityIssue = true
                errorMessage = error.localizedDescription
                return
            }
            guard isCurrentAuthorization(generation) else { return }
            isRequestingAuthorization = false
            let updated = await client.authorizationState()
            guard isCurrentAuthorization(generation) else { return }
            isRequestingAuthorization = false
            updateCapability(for: updated)
        }

        guard isCurrentAuthorization(generation) else { return }
        isRequestingAuthorization = false
        if authorizationState.status == .denied || !authorizationState.canDeliver {
            disablePreferenceForCapabilityIssue(authorizationState)
            return
        }
        updateCapability(for: authorizationState)
    }

    private func isCurrentAuthorization(_ generation: UInt64) -> Bool {
        !hasShutDown && generation == authorizationGeneration && isEnabled
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        !hasShutDown && generation == authorizationGeneration
    }

    private func isCurrentDelivery(_ generation: UInt64, event: KeepAwakeTimerFinishedEvent) -> Bool {
        isCurrentAuthorization(generation) && latestAttemptedGeneration == event.sessionGeneration
    }

    nonisolated static func foregroundPresentationOptions(includesSound: Bool) -> UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if includesSound { options.insert(.sound) }
        return options
    }

    private func updateCapability(for state: NotificationAuthorizationState, preservingDisabledIssue: Bool = false) {
        authorizationState = state
        if isRequestingAuthorization {
            capabilityState = .permissionPending
            return
        }
        if !isEnabled && !preservingDisabledIssue {
            capabilityState = .off
            errorMessage = nil
            return
        }
        if !isEnabled && preservingDisabledIssue && state.status != .denied && state.canDeliver {
            isShowingCapabilityIssue = false
            capabilityState = .off
            errorMessage = nil
            return
        }
        switch state.status {
        case .notDetermined:
            capabilityState = isEnabled ? .permissionPending : .off
            errorMessage = nil
        case .denied:
            capabilityState = .denied
            isShowingCapabilityIssue = true
            errorMessage = nil
        case .authorized where !state.canDeliver:
            capabilityState = .deliverySurfaceDisabled
            isShowingCapabilityIssue = true
            errorMessage = nil
        case .authorized:
            capabilityState = .authorized
            isShowingCapabilityIssue = false
            errorMessage = nil
        }
    }

    private func disablePreferenceForCapabilityIssue(_ state: NotificationAuthorizationState) {
        clearFailedDelivery()
        isDelivering = false
        isEnabled = false
        isRequestingAuthorization = false
        preferences.set(false, forKey: Self.enabledPreferenceKey)
        isShowingCapabilityIssue = true
        updateCapability(for: state, preservingDisabledIssue: true)
    }

    private static func readAndMigratePreference(from preferences: UserDefaults) -> Bool {
        if let value = preferences.object(forKey: Self.enabledPreferenceKey) as? Bool {
            preferences.removeObject(forKey: Self.legacyKeepAwakeTimerPreferenceKey)
            return value
        }
        guard let legacyValue = preferences.object(forKey: Self.legacyKeepAwakeTimerPreferenceKey) as? Bool else {
            return false
        }
        preferences.set(legacyValue, forKey: Self.enabledPreferenceKey)
        preferences.removeObject(forKey: Self.legacyKeepAwakeTimerPreferenceKey)
        return legacyValue
    }
}

extension NotificationsController: KeepAwakeTimerFinishedNotifying {}
