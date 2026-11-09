import AppKit
import CoreLocation
import Foundation

nonisolated enum NetworkNamePermissionState: Equatable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
    case servicesDisabled
    case unknown
}

@MainActor
protocol NetworkNamePermissionChecking: AnyObject {
    var state: NetworkNamePermissionState { get }
    var onChange: ((NetworkNamePermissionState) -> Void)? { get set }

    func refresh()
    func request()
    func openSettings() -> Bool
    func shutdown()
}

@MainActor
final class NetworkNamePermissionClient: NSObject, NetworkNamePermissionChecking, CLLocationManagerDelegate {
    private let manager: CLLocationManager?
    private let openURL: (URL) -> Bool
    private let readState: () -> NetworkNamePermissionState
    private let requestWhenInUse: () -> Void
    private let isApplicationActive: () -> Bool
    private let hasUsageDescription: () -> Bool

    private(set) var state: NetworkNamePermissionState = .unknown
    var onChange: ((NetworkNamePermissionState) -> Void)?

    private var hasPendingNativeRequest = false
    private var pendingRequestSawDeactivation = false
    private var shutdownGeneration: UInt64 = 0
    private var isShutdown = false

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         readState: (() -> NetworkNamePermissionState)? = nil,
         requestWhenInUse: (() -> Void)? = nil,
         isApplicationActive: (() -> Bool)? = nil,
         hasUsageDescription: (() -> Bool)? = nil) {
        // Inject native boundaries for tests without constructing a real location manager.
        let manager = readState == nil ? CLLocationManager() : nil
        self.manager = manager
        self.openURL = openURL
        self.readState = readState ?? {
            guard let manager else { return .unknown }
            return Self.authorizationState(status: manager.authorizationStatus,
                servicesEnabled: CLLocationManager.locationServicesEnabled())
        }
        self.requestWhenInUse = requestWhenInUse ?? { manager?.requestWhenInUseAuthorization() }
        self.isApplicationActive = isApplicationActive ?? { NSApp.isActive }
        self.hasUsageDescription = hasUsageDescription ?? {
            guard let description = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String else { return false }
            return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        super.init()

        manager?.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        refresh()
    }

    func refresh() {
        guard !isShutdown else { return }

        let observedState = readState()
        if hasPendingNativeRequest {
            if observedState != .notDetermined {
                clearPendingRequest()
            } else {
                // Keep the issued request in flight while its native prompt is open.
                publish(.requesting)
                return
            }
        }

        publish(observedState)
    }

    func request() {
        guard !isShutdown else { return }

        // Reconcile first so an already-resolved grant or denial is never left
        // waiting for a delegate callback that may not arrive.
        refresh()
        guard state == .notDetermined,
              !hasPendingNativeRequest,
              isApplicationActive(),
              hasUsageDescription() else {
            return
        }

        hasPendingNativeRequest = true
        pendingRequestSawDeactivation = false
        let requestGeneration = shutdownGeneration
        publish(.requesting)

        // An observer may synchronously shut this client down while handling
        // the requesting state change.
        guard !isShutdown, shutdownGeneration == requestGeneration else { return }
        requestWhenInUse()
    }

    func openSettings() -> Bool {
        guard !isShutdown else { return false }

        if let locationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"),
           openURL(locationSettingsURL) {
            return true
        }

        return openURL(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        shutdownGeneration &+= 1
        hasPendingNativeRequest = false
        pendingRequestSawDeactivation = false
        manager?.delegate = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        onChange = nil
        state = .unknown
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CLLocationManager delegate delivery is bridged explicitly because
        // this adapter owns all mutable state on MainActor.
        Task { @MainActor [weak self] in
            self?.authorizationDidChange()
        }
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        guard !isShutdown, hasPendingNativeRequest else { return }
        pendingRequestSawDeactivation = true
    }

    @objc
    private func applicationDidBecomeActive(_ notification: Notification) {
        guard !isShutdown else { return }

        let generation = shutdownGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown, self.shutdownGeneration == generation else { return }

            if self.hasPendingNativeRequest, self.pendingRequestSawDeactivation {
                // Returning to the foreground is an explicit reconciliation
                // point if the authorization callback did not arrive.
                self.clearPendingRequest()
            }
            self.refresh()
        }
    }

    nonisolated static func authorizationState(status: CLAuthorizationStatus, servicesEnabled: Bool) -> NetworkNamePermissionState {
        guard servicesEnabled else { return .servicesDisabled }
        return switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    func authorizationDidChange() {
        guard !isShutdown else { return }
        let observed = readState()
        if hasPendingNativeRequest && observed == .notDetermined {
            publish(.requesting)
        } else {
            clearPendingRequest()
            publish(observed)
        }
    }

    private func clearPendingRequest() {
        hasPendingNativeRequest = false
        pendingRequestSawDeactivation = false
    }

    private func publish(_ nextState: NetworkNamePermissionState) {
        guard state != nextState else { return }
        state = nextState
        onChange?(nextState)
    }
}

#if DEBUG
@MainActor
final class PreviewNetworkNamePermission: NetworkNamePermissionChecking {
    var state: NetworkNamePermissionState {
        didSet {
            if oldValue != state {
                onChange?(state)
            }
        }
    }

    var onChange: ((NetworkNamePermissionState) -> Void)?

    init(state: NetworkNamePermissionState = .notDetermined) {
        self.state = state
    }

    func refresh() {}

    func request() {
        guard state == .notDetermined else { return }
        state = .requesting
    }

    func openSettings() -> Bool { false }

    func shutdown() {
        onChange = nil
        state = .unknown
    }
}

#endif
