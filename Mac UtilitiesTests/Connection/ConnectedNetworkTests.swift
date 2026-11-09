import Foundation
import AppKit
import CoreLocation
import Network
import Testing
@testable import Mac_Utilities

private func connectedPath(
    _ usedTypes: Set<NetworkTransport>,
    wifiInterfaces: [String] = []
) -> NetworkPathSnapshot {
    NetworkPathSnapshot(status: .available, usedTypes: usedTypes, wifiInterfaces: Set(wifiInterfaces))
}

private struct ConnectedNetworkLabelCase {
    let name: String
    let path: NetworkPathSnapshot
    let networkName: String?
    let interface: String?
    let authorized: Bool
    let expected: ConnectedNetworkLabel
}

@Suite(.serialized)
struct ConnectedNetworkPresentationTests {
    @Test func resolvesConnectedNetworkLabelsFromPathAndMatchingAssociation() {
        let cases = [
            ConnectedNetworkLabelCase(
                name: "pending path",
                path: NetworkPathSnapshot(), networkName: "Home", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Checking…", symbol: "network", accessibilityValue: "Checking Connection")
            ),
            ConnectedNetworkLabelCase(
                name: "unavailable path",
                path: NetworkPathSnapshot(status: .unavailable, usedTypes: [.wifi]), networkName: nil, interface: nil, authorized: false,
                expected: ConnectedNetworkLabel(title: "Offline", symbol: "wifi.slash", accessibilityValue: "No Network Connection")
            ),
            ConnectedNetworkLabelCase(
                name: "authorized unique Wi-Fi match",
                path: connectedPath([.wifi], wifiInterfaces: ["en0"]), networkName: "Home Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Home Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi, Home Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "duplicate entries for the same physical Wi-Fi interface",
                path: connectedPath([.wifi], wifiInterfaces: ["en0", "en0"]), networkName: "Home Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Home Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi, Home Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "unauthorized Wi-Fi name",
                path: connectedPath([.wifi], wifiInterfaces: ["en0"]), networkName: "Home Wi-Fi", interface: "en0", authorized: false,
                expected: ConnectedNetworkLabel(title: "Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "authorized but unavailable name",
                path: connectedPath([.wifi], wifiInterfaces: ["en0"]), networkName: nil, interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "wrong interface association",
                path: connectedPath([.wifi], wifiInterfaces: ["en1"]), networkName: "Unrelated Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "multiple Wi-Fi candidates",
                path: connectedPath([.wifi], wifiInterfaces: ["en0", "en1"]), networkName: "Possibly unrelated", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi")
            ),
            ConnectedNetworkLabelCase(
                name: "wired path with an unused Wi-Fi candidate",
                path: connectedPath([.ethernet], wifiInterfaces: ["en0"]), networkName: "Home Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Ethernet", symbol: "network", accessibilityValue: "Ethernet")
            ),
            ConnectedNetworkLabelCase(
                name: "simultaneous transport types",
                path: connectedPath([.wifi, .ethernet], wifiInterfaces: ["en0"]), networkName: "Home Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Network", symbol: "network", accessibilityValue: "Network")
            ),
            ConnectedNetworkLabelCase(
                name: "loopback transport",
                path: connectedPath([.loopback]), networkName: nil, interface: nil, authorized: false,
                expected: ConnectedNetworkLabel(title: "Network", symbol: "network", accessibilityValue: "Network")
            ),
            ConnectedNetworkLabelCase(
                name: "other transport",
                path: connectedPath([.other]), networkName: nil, interface: nil, authorized: false,
                expected: ConnectedNetworkLabel(title: "Network", symbol: "network", accessibilityValue: "Network")
            ),
            ConnectedNetworkLabelCase(
                name: "unknown used transport",
                path: connectedPath([]), networkName: "Home Wi-Fi", interface: "en0", authorized: true,
                expected: ConnectedNetworkLabel(title: "Network", symbol: "network", accessibilityValue: "Network")
            )
        ]

        for testCase in cases {
            let actual = ConnectedNetworkLabel.resolve(
                path: testCase.path,
                name: testCase.networkName,
                interface: testCase.interface,
                authorized: testCase.authorized
            )
            #expect(actual == testCase.expected, "Unexpected label for \(testCase.name)")
        }
    }

    @Test func sanitizesUnicodeDisplayNamesWithoutChangingOrdinaryText() {
        let raw = "  Café\u{0000}\u{202E} 東京\n  "

        #expect(ConnectedNetworkLabel.sanitizedName(raw) == "Café   東京")
        #expect(ConnectedNetworkLabel.sanitizedName(" \n\u{202E} ") == nil)
        #expect(ConnectedNetworkLabel.sanitizedName("東京 · Café") == "東京 · Café")
    }
}

#if DEBUG
@Suite(.serialized)
struct NetworkLabelLaunchModeTests {
    @Test func parsesSupportedFixtureAndNativeCheckModifiers() throws {
        #expect(try NetworkLabelLaunchMode.parse([]) == .ordinary)

        for state in NetworkLabelPreviewState.allCases {
            let arguments = ["--usage-preview=history", "--network-label-preview=\(state.rawValue)"]
            #expect(try NetworkLabelLaunchMode.parse(arguments) == .fixture(state))
        }

        #expect(try NetworkLabelLaunchMode.parse([
            "--usage-preview=history", "--network-label-native-check"
        ]) == .nativeCheck)
        #expect(try NetworkLabelLaunchMode.parse([
            "--usage-preview=history", "--usage-preview-light", "--usage-preview-compact", "--network-label-preview=denied"
        ]) == .fixture(.denied))
        #expect(try NetworkLabelLaunchMode.parse([
            "--usage-preview=history", "--usage-preview-expanded", "--network-label-native-check"
        ]) == .nativeCheck)
    }

    @Test func rejectsInvalidOrConflictingModifiers() {
        let invalidArguments: [[String]] = [
            ["--network-label-preview=wifi"],
            ["--usage-preview=empty", "--network-label-preview=wifi"],
            ["--usage-preview=history", "--usage-preview=history", "--network-label-preview=wifi"],
            ["--usage-preview=history", "--network-label-preview=unknown"],
            ["--usage-preview=history", "--network-label-preview"],
            ["--usage-preview=history", "--network-label-native-check=true"],
            ["--usage-preview=history", "--network-label-preview=wifi", "--network-label-native-check"],
            ["--usage-preview=history", "--network-label-preview=wifi", "--network-label-preview=ethernet"]
        ]

        for arguments in invalidArguments {
            #expect(throws: NetworkLabelLaunchMode.InvalidArguments.self) {
                try NetworkLabelLaunchMode.parse(arguments)
            }
        }
    }
}
#endif

@MainActor
private final class ConnectedNetworkTestPermission: NetworkNamePermissionChecking {
    var state: NetworkNamePermissionState
    var onChange: ((NetworkNamePermissionState) -> Void)?
    private(set) var requestCount = 0
    private(set) var refreshCount = 0
    private(set) var shutdownCount = 0
    var settingsOpenResult = true

    init(state: NetworkNamePermissionState = .notDetermined) {
        self.state = state
    }

    func refresh() { refreshCount += 1 }

    func request() { requestCount += 1 }

    func openSettings() -> Bool { settingsOpenResult }

    func shutdown() { shutdownCount += 1 }

    func emit(_ state: NetworkNamePermissionState) {
        self.state = state
        onChange?(state)
    }
}

private actor ConnectedNetworkSnapshotReader: WiFiQualityReading {
    private let snapshots: [WiFiQualitySnapshot]
    private var readCountValue = 0
    private var permissionValues: [Bool] = []

    init(_ snapshots: [WiFiQualitySnapshot]) {
        self.snapshots = snapshots
    }

    func read() async -> WiFiQualitySnapshot {
        await read(allowNetworkName: false)
    }

    func read(allowNetworkName: Bool) async -> WiFiQualitySnapshot {
        let index = readCountValue
        readCountValue += 1
        permissionValues.append(allowNetworkName)
        return snapshots[min(index, snapshots.count - 1)]
    }

    func readCount() -> Int { readCountValue }

    func nameReadPermissions() -> [Bool] { permissionValues }
}

private actor DeferredConnectedNetworkReader: WiFiQualityReading {
    private var readCountValue = 0
    private var permissionValues: [Bool] = []
    private var pending: [CheckedContinuation<WiFiQualitySnapshot, Never>] = []

    func read() async -> WiFiQualitySnapshot {
        await read(allowNetworkName: false)
    }

    func read(allowNetworkName: Bool) async -> WiFiQualitySnapshot {
        readCountValue += 1
        permissionValues.append(allowNetworkName)
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    func readCount() -> Int { readCountValue }

    func nameReadPermissions() -> [Bool] { permissionValues }

    func resolveNext(with snapshot: WiFiQualitySnapshot) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: snapshot)
    }
}

@MainActor
private func waitForConnectedNetworkReads(
    _ count: Int,
    from reader: ConnectedNetworkSnapshotReader
) async {
    for _ in 0..<2_000 {
        if await reader.readCount() >= count { return }
        await Task.yield()
    }
    #expect(await reader.readCount() >= count)
}

@MainActor
private func waitForConnectedNetworkReads(
    _ count: Int,
    from reader: DeferredConnectedNetworkReader
) async {
    for _ in 0..<2_000 {
        if await reader.readCount() >= count { return }
        await Task.yield()
    }
    #expect(await reader.readCount() >= count)
}

@MainActor
private func waitForConnectedNetworkSnapshot(
    _ expected: WiFiQualitySnapshot,
    from monitor: WiFiQualityMonitor
) async {
    for _ in 0..<2_000 where monitor.snapshot != expected {
        await Task.yield()
    }
    #expect(monitor.snapshot == expected)
}

@Suite(.serialized)
@MainActor
struct ConnectedNetworkMonitorTests {
    @Test func consumersShareSamplingAndPathObservationUntilBothHide() async {
        let result = WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_101),
            interfaceName: "en0", networkName: "Studio", signalDBm: -48
        )
        let reader = ConnectedNetworkSnapshotReader([result])
        let path = connectedPath([.wifi], wifiInterfaces: ["en0"])
        let pathReader = PreviewNetworkPathReader(snapshot: path)
        let permission = ConnectedNetworkTestPermission(state: .authorized)
        let monitor = WiFiQualityMonitor(
            reader: reader, pathReader: pathReader, permission: permission, refreshInterval: .seconds(30)
        )
        defer { monitor.shutdown() }

        monitor.setVisible(true, for: .connection)
        await waitForConnectedNetworkReads(1, from: reader)
        await waitForConnectedNetworkSnapshot(result, from: monitor)
        #expect(pathReader.startCount == 1)
        #expect(monitor.networkLabel.title == "Studio")

        monitor.setVisible(true, for: .popover)
        monitor.setVisible(true, for: .popover)
        monitor.setVisible(false, for: .connection)
        #expect(monitor.isVisible)
        #expect(pathReader.startCount == 1)
        #expect(pathReader.stopCount == 0)
        #expect(monitor.snapshot == result)

        // An unchanged path must not clear the current identity or restart the read loop.
        pathReader.emit(path)
        await Task.yield()
        #expect(monitor.snapshot == result)
        #expect(await reader.readCount() == 1)

        monitor.setVisible(false, for: .popover)
        #expect(!monitor.isVisible)
        #expect(pathReader.stopCount == 1)
        #expect(monitor.snapshot == nil)
        #expect(monitor.path == NetworkPathSnapshot())

        // The preview path reader drops its stopped callback, so late fake events cannot revive state.
        pathReader.emit(path)
        #expect(monitor.path == NetworkPathSnapshot())
        #expect(await reader.readCount() == 1)
    }

    @Test func permissionRevocationRejectsDelayedNameAndKeepsMetrics() async {
        let reader = DeferredConnectedNetworkReader()
        let pathReader = PreviewNetworkPathReader(snapshot: connectedPath([.wifi], wifiInterfaces: ["en0"]))
        let permission = ConnectedNetworkTestPermission(state: .authorized)
        let monitor = WiFiQualityMonitor(
            reader: reader, pathReader: pathReader, permission: permission, refreshInterval: .seconds(30)
        )
        defer { monitor.shutdown() }

        monitor.setVisible(true, for: .connection)
        await waitForConnectedNetworkReads(1, from: reader)
        #expect(await reader.nameReadPermissions() == [true])

        permission.emit(.denied)
        #expect(monitor.snapshot == nil)
        await reader.resolveNext(with: WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_111),
            interfaceName: "en0", networkName: "Revoked Network", signalDBm: -51
        ))

        await waitForConnectedNetworkReads(2, from: reader)
        #expect(monitor.snapshot == nil)
        #expect(await reader.nameReadPermissions() == [true, false])

        let deniedResult = WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_112),
            interfaceName: "en0", networkName: "Must Be Removed", signalDBm: -54
        )
        await reader.resolveNext(with: deniedResult)
        await waitForConnectedNetworkSnapshot(WiFiQualitySnapshot(
            sampledAt: deniedResult.sampledAt, interfaceName: "en0", signalDBm: -54
        ), from: monitor)

        #expect(monitor.snapshot?.networkName == nil)
        #expect(monitor.snapshot?.signalDBm == -54)
        #expect(monitor.networkLabel.title == "Wi-Fi")
    }

    @Test func settingsFailureIsVisibleAndClearsAfterSuccessfulRecovery() {
        let permission = ConnectedNetworkTestPermission(state: .denied)
        permission.settingsOpenResult = false
        let monitor = WiFiQualityMonitor(permission: permission)
        defer { monitor.shutdown() }
        monitor.openLocationSettings()
        #expect(monitor.settingsOpenFailed)
        permission.settingsOpenResult = true
        monitor.openLocationSettings()
        #expect(!monitor.settingsOpenFailed)
        #expect(permission.state == .denied)
    }

    @Test func authorizedNameSurvivesWhenQualityMetricsAreUnavailable() async {
        let result = WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_121),
            interfaceName: "en0", networkName: "名字 · Café"
        )
        let reader = ConnectedNetworkSnapshotReader([result])
        let pathReader = PreviewNetworkPathReader(snapshot: connectedPath([.wifi], wifiInterfaces: ["en0"]))
        let permission = ConnectedNetworkTestPermission(state: .authorized)
        let monitor = WiFiQualityMonitor(
            reader: reader, pathReader: pathReader, permission: permission, refreshInterval: .seconds(30)
        )
        defer { monitor.shutdown() }

        monitor.setVisible(true, for: .connection)
        await waitForConnectedNetworkReads(1, from: reader)
        await waitForConnectedNetworkSnapshot(result, from: monitor)

        #expect(monitor.snapshot?.availability == .unavailable)
        #expect(monitor.snapshot?.hasAnyReading == false)
        #expect(monitor.snapshot?.networkName == "名字 · Café")
        #expect(monitor.networkLabel.title == "名字 · Café")
        #expect(monitor.associatedName == "名字 · Café")
    }

    @Test func sleepInvalidatesPendingNameBeforeWakeRefresh() async {
        let reader = DeferredConnectedNetworkReader()
        let pathReader = PreviewNetworkPathReader(snapshot: connectedPath([.wifi], wifiInterfaces: ["en0"]))
        let permission = ConnectedNetworkTestPermission(state: .authorized)
        let monitor = WiFiQualityMonitor(
            reader: reader, pathReader: pathReader, permission: permission, refreshInterval: .seconds(30)
        )
        defer { monitor.shutdown() }

        monitor.setVisible(true, for: .popover)
        await waitForConnectedNetworkReads(1, from: reader)
        monitor.prepareForSleep()
        #expect(monitor.snapshot == nil)
        #expect(monitor.path == NetworkPathSnapshot())
        #expect(pathReader.stopCount == 1)

        await reader.resolveNext(with: WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_131),
            interfaceName: "en0", networkName: "Before Sleep", signalDBm: -47
        ))
        for _ in 0..<20 { await Task.yield() }
        #expect(monitor.snapshot == nil)
        #expect(await reader.readCount() == 1)

        monitor.refreshAfterWake()
        await waitForConnectedNetworkReads(2, from: reader)
        #expect(monitor.snapshot == nil)
        await reader.resolveNext(with: WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_132),
            interfaceName: "en0", networkName: "After Wake", signalDBm: -49
        ))
        await waitForConnectedNetworkSnapshot(WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_132),
            interfaceName: "en0", networkName: "After Wake", signalDBm: -49
        ), from: monitor)
        #expect(pathReader.startCount == 2)
    }
}

@Suite(.serialized)
@MainActor
struct NetworkNamePermissionTests {
    @Test func noOpRequestsDoNotEnterRequestingOrInvokeNativeAPI() {
        for initial in [NetworkNamePermissionState.authorized, .denied, .restricted, .servicesDisabled, .unknown] {
            var nativeRequests = 0
            let client = NetworkNamePermissionClient(readState: { initial },
                requestWhenInUse: { nativeRequests += 1 }, isApplicationActive: { true }, hasUsageDescription: { true })
            client.request()
            #expect(client.state == initial)
            #expect(nativeRequests == 0)
            client.shutdown()
        }
        for (active, purpose) in [(false, true), (true, false)] {
            var nativeRequests = 0
            let client = NetworkNamePermissionClient(readState: { .notDetermined },
                requestWhenInUse: { nativeRequests += 1 }, isApplicationActive: { active }, hasUsageDescription: { purpose })
            client.request()
            #expect(client.state == .notDetermined)
            #expect(nativeRequests == 0)
            client.shutdown()
        }
    }

    @Test func pendingRequestsAreDeduplicatedAndLateCallbacksCannotReviveShutdown() {
        var observed = NetworkNamePermissionState.notDetermined
        var nativeRequests = 0
        var changes: [NetworkNamePermissionState] = []
        let client = NetworkNamePermissionClient(readState: { observed }, requestWhenInUse: { nativeRequests += 1 },
            isApplicationActive: { true }, hasUsageDescription: { true })
        client.onChange = { changes.append($0) }
        client.request()
        client.request()
        client.refresh()
        client.authorizationDidChange() // Initial not-determined callback does not cancel an issued prompt.
        #expect(client.state == .requesting)
        #expect(nativeRequests == 1)
        observed = .authorized
        client.authorizationDidChange()
        #expect(client.state == .authorized)
        #expect(changes == [.requesting, .authorized])
        client.shutdown()
        observed = .denied
        client.authorizationDidChange()
        client.request()
        #expect(client.state == .unknown)
        #expect(nativeRequests == 1)
        #expect(changes == [.requesting, .authorized])
    }

    @Test func foregroundReturnReconcilesAnUnresolvedRequestWithoutAutomaticallyReissuing() async {
        var nativeRequests = 0
        let client = NetworkNamePermissionClient(readState: { .notDetermined },
            requestWhenInUse: { nativeRequests += 1 }, isApplicationActive: { true }, hasUsageDescription: { true })
        defer { client.shutdown() }
        client.request()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(client.state == .requesting)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for _ in 0..<100 where client.state == .requesting { await Task.yield() }
        #expect(client.state == .notDetermined)
        #expect(nativeRequests == 1)
    }

    @Test func settingsOpenUsesFallbackAndReportsFailure() {
        for outcomes in [[true], [false, true], [false, false]] {
            var opened: [URL] = []
            let client = NetworkNamePermissionClient(openURL: { url in
                opened.append(url)
                return outcomes[opened.count - 1]
            }, readState: { .denied }, requestWhenInUse: {})
            #expect(client.openSettings() == outcomes.last)
            #expect(opened.count == outcomes.count)
            #expect(opened.first?.scheme == "x-apple.systempreferences")
            if outcomes.count == 2 { #expect(opened.last?.path == "/System/Applications/System Settings.app") }
            client.shutdown()
            #expect(!client.openSettings())
        }
    }

    @Test func disabledServicesOverrideTheMacOSGrant() {
        #expect(NetworkNamePermissionClient.authorizationState(status: .authorizedAlways, servicesEnabled: false) == .servicesDisabled)
        #expect(NetworkNamePermissionClient.authorizationState(status: .authorizedAlways, servicesEnabled: true) == .authorized)
        #expect(NetworkNamePermissionClient.authorizationState(status: .denied, servicesEnabled: true) == .denied)
        #expect(NetworkNamePermissionClient.authorizationState(status: .restricted, servicesEnabled: true) == .restricted)
        #expect(NetworkPathReader.status(for: .requiresConnection) == .unavailable)
        #expect(NetworkPathReader.status(for: .unsatisfied) == .unavailable)
        #expect(NetworkPathReader.status(for: .satisfied) == .available)
    }
}
