import Combine
import Foundation

@MainActor
final class WiFiQualityMonitor: ObservableObject {
    enum Consumer: Hashable { case connection, popover }
    @Published private(set) var snapshot: WiFiQualitySnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var path = NetworkPathSnapshot()
    @Published private(set) var permissionState: NetworkNamePermissionState = .notDetermined
    @Published private(set) var settingsOpenFailed = false
    let isSimulated: Bool
    private(set) var isVisible = false

    private let reader: any WiFiQualityReading
    private let pathReader: any NetworkPathReading
    private let permission: any NetworkNamePermissionChecking
    private let refreshInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var consumers: Set<Consumer> = []
    private var pollingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pathGeneration: UInt64 = 0
    private var hasShutDown = false
    private var isSleeping = false

    init(reader: any WiFiQualityReading = CoreWLANWiFiQualityReader(),
         pathReader: (any NetworkPathReading)? = nil,
         permission: (any NetworkNamePermissionChecking)? = nil,
         isSimulated: Bool = false,
         refreshInterval: Duration = .seconds(5),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) }) {
        #if DEBUG
        let permission = permission ?? PreviewNetworkNamePermission()
        let pathReader = pathReader ?? PreviewNetworkPathReader()
        #else
        let permission = permission ?? NetworkNamePermissionClient()
        let pathReader = pathReader ?? NetworkPathReader()
        #endif
        self.reader = reader
        self.pathReader = pathReader
        self.permission = permission
        self.isSimulated = isSimulated
        self.refreshInterval = refreshInterval
        self.sleep = sleep
        permissionState = permission.state
        permission.onChange = { [weak self] state in self?.permissionChanged(state) }
    }

    var networkLabel: ConnectedNetworkLabel {
        ConnectedNetworkLabel.resolve(path: path, name: snapshot?.networkName,
            interface: snapshot?.interfaceName, authorized: permissionState == .authorized,
            initialWiFiSamplePending: snapshot == nil && isRefreshing)
    }

    var associatedName: String? {
        guard permissionState == .authorized else { return nil }
        return ConnectedNetworkLabel.sanitizedName(snapshot?.networkName)
    }

    // Compatibility for existing Connection-only callers and injected regressions.
    func setVisible(_ visible: Bool) { setVisible(visible, for: .connection) }

    func setVisible(_ visible: Bool, for consumer: Consumer) {
        guard !hasShutDown else { return }
        let previous = consumers
        if visible { consumers.insert(consumer) } else { consumers.remove(consumer) }
        guard consumers != previous else { return }
        let active = !consumers.isEmpty
        guard active != isVisible else { return }
        isVisible = active
        invalidate(clearSnapshot: true)
        if active && !isSleeping {
            refreshAuthorization()
            startPathObservation()
            startPollingIfNeeded()
        } else {
            stopPathObservation()
            path = NetworkPathSnapshot()
        }
    }

    func refreshAfterWake(isVisible visible: Bool) {
        if visible { consumers.insert(.connection) } else { consumers.remove(.connection) }
        refreshAfterWake()
    }

    func prepareForSleep() {
        guard !hasShutDown else { return }
        isSleeping = true
        invalidate(clearSnapshot: true)
        stopPathObservation()
        path = NetworkPathSnapshot()
    }

    func refreshAfterWake() {
        guard !hasShutDown else { return }
        isSleeping = false
        isVisible = !consumers.isEmpty
        invalidate(clearSnapshot: true)
        stopPathObservation()
        path = NetworkPathSnapshot()
        guard isVisible else { return }
        refreshAuthorization()
        startPathObservation()
        startPollingIfNeeded()
    }

    func refreshAuthorization() {
        guard !hasShutDown else { return }
        permission.refresh()
        permissionChanged(permission.state)
    }

    func requestNetworkName() {
        guard !hasShutDown, !isSimulated, permissionState == .notDetermined else { return }
        permission.request()
        permissionChanged(permission.state)
    }

    func openLocationSettings() {
        guard !hasShutDown, !isSimulated else { return }
        settingsOpenFailed = !permission.openSettings()
    }

    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        consumers.removeAll()
        isVisible = false
        invalidate(clearSnapshot: true)
        stopPathObservation()
        permission.onChange = nil
        permission.shutdown()
        path = NetworkPathSnapshot()
    }

    private func permissionChanged(_ state: NetworkNamePermissionState) {
        guard !hasShutDown, permissionState != state else { return }
        permissionState = state
        settingsOpenFailed = false
        invalidate(clearSnapshot: true)
        startPollingIfNeeded()
    }

    private func stopPathObservation() {
        pathGeneration &+= 1
        pathReader.stop()
    }

    private func startPathObservation() {
        let pathToken = pathGeneration
        pathReader.start { [weak self] value in
            guard let self, self.pathGeneration == pathToken, self.isVisible, !self.isSleeping, !self.hasShutDown, self.path != value else { return }
            self.path = value
            self.invalidate(clearSnapshot: true)
            self.startPollingIfNeeded()
        }
    }

    private func invalidate(clearSnapshot: Bool) {
        generation &+= 1
        pollingTask?.cancel()
        if clearSnapshot { snapshot = nil }
        isRefreshing = isVisible && !isSleeping && !hasShutDown
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil, isVisible, !isSleeping, !hasShutDown else { return }
        let token = generation
        pollingTask = Task { [weak self] in await self?.poll(generation: token) }
    }

    private func poll(generation token: UInt64) async {
        while shouldPoll(token) {
            refreshAuthorization()
            guard shouldPoll(token) else { break }
            isRefreshing = true
            let allowed = permissionState == .authorized
            let next = await reader.read(allowNetworkName: allowed)
            guard shouldPoll(token) else { break }
            // Recheck authorization after an actor hop before publishing identity.
            refreshAuthorization()
            guard shouldPoll(token) else { break }
            snapshot = WiFiQualitySnapshot(sampledAt: next.sampledAt, interfaceName: next.interfaceName,
                networkName: allowed && permissionState == .authorized ? next.networkName : nil,
                signalDBm: next.signalDBm, noiseDBm: next.noiseDBm, channelNumber: next.channelNumber,
                channelBand: next.channelBand, channelWidth: next.channelWidth,
                transmitRateMbps: next.transmitRateMbps, availability: next.availability)
            isRefreshing = false
            do { try await sleep(refreshInterval) } catch { break }
        }
        pollingTask = nil
        if isVisible && !isSleeping && !hasShutDown {
            isRefreshing = true
            startPollingIfNeeded()
        } else { isRefreshing = false }
    }

    private func shouldPoll(_ token: UInt64) -> Bool {
        isVisible && !isSleeping && !hasShutDown && generation == token && !Task.isCancelled
    }
}
