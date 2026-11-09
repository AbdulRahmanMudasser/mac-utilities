import Network

@MainActor
protocol NetworkPathReading: AnyObject {
    func start(_ receive: @escaping @MainActor (NetworkPathSnapshot) -> Void)
    func stop()
}

@MainActor
final class NetworkPathReader: NetworkPathReading {
    private var monitor: NWPathMonitor?
    private var generation: UInt64 = 0

    func start(_ receive: @escaping @MainActor (NetworkPathSnapshot) -> Void) {
        guard monitor == nil else { return }
        generation &+= 1
        let token = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        receive(NetworkPathSnapshot())
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Self.snapshot(path)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil, self.generation == token else { return }
                receive(snapshot)
            }
        }
        monitor.start(queue: DispatchQueue(label: "MacUtilities.ConnectionLabel.path"))
    }

    func stop() {
        generation &+= 1
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
    }

    nonisolated static func status(for status: NWPath.Status) -> NetworkPathSnapshot.Status {
        switch status {
        case .satisfied: return .available
        case .unsatisfied, .requiresConnection: return .unavailable
        @unknown default: return .pending
        }
    }

    nonisolated private static func snapshot(_ path: NWPath) -> NetworkPathSnapshot {
        let types: [(NWInterface.InterfaceType, NetworkTransport)] = [
            (.wifi, .wifi), (.wiredEthernet, .ethernet), (.cellular, .cellular), (.loopback, .loopback), (.other, .other)
        ]
        return NetworkPathSnapshot(status: Self.status(for: path.status),
            usedTypes: Set(types.filter { path.usesInterfaceType($0.0) }.map(\.1)),
            wifiInterfaces: Set(path.availableInterfaces.filter { $0.type == .wifi }.map(\.name)))
    }
}

#if DEBUG
@MainActor
final class PreviewNetworkPathReader: NetworkPathReading {
    var snapshot: NetworkPathSnapshot
    private var receive: (@MainActor (NetworkPathSnapshot) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    init(snapshot: NetworkPathSnapshot = NetworkPathSnapshot()) { self.snapshot = snapshot }
    func start(_ receive: @escaping @MainActor (NetworkPathSnapshot) -> Void) {
        guard self.receive == nil else { return }
        startCount += 1
        self.receive = receive
        receive(snapshot)
    }
    func emit(_ value: NetworkPathSnapshot) { snapshot = value; receive?(value) }
    func stop() { if receive != nil { stopCount += 1 }; receive = nil }
}

#endif
