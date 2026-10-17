import AppKit
import Network

@MainActor
final class ConnectionObservationEvents: StabilityEventSource {
    private var monitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?
    private var workspaceNotificationCenter: NotificationCenter?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var receive: (@MainActor (StabilityEnvironmentEvent) -> Void)?

    private var generation: UInt64 = 0
    private var isRunning = false
    var isObserving: Bool { isRunning }

    func start(_ receive: @escaping @MainActor (StabilityEnvironmentEvent) -> Void) {
        guard !isRunning else { return }

        generation &+= 1
        let runGeneration = generation
        isRunning = true
        self.receive = receive

        // The owner needs an explicit pending state before any monitor result is delivered.
        receive(.path(.pending))
        guard isActive(runGeneration) else { return }

        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "MacUtilities.ConnectionObservationEvents.path")
        self.monitor = monitor
        monitorQueue = queue

        monitor.pathUpdateHandler = { [weak self] path in
            // Reduce NWPath to a Sendable value before crossing onto the main actor.
            let state = Self.pathState(for: path)
            Task { @MainActor [weak self] in
                self?.deliver(.path(state), generation: runGeneration)
            }
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter = notificationCenter
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliverWorkspace(.sleep, generation: runGeneration)
        }
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliverWorkspace(.wake, generation: runGeneration)
        }

        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning || monitor != nil || monitorQueue != nil
                || workspaceNotificationCenter != nil || receive != nil else {
            return
        }

        // Invalidate queued callbacks before cancelling the monitor or removing observers.
        generation &+= 1
        isRunning = false
        receive = nil

        if let monitor {
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
        monitor = nil
        monitorQueue = nil

        if let workspaceNotificationCenter {
            if let sleepObserver {
                workspaceNotificationCenter.removeObserver(sleepObserver)
            }
            if let wakeObserver {
                workspaceNotificationCenter.removeObserver(wakeObserver)
            }
        }
        sleepObserver = nil
        wakeObserver = nil
        workspaceNotificationCenter = nil
    }

    private func isActive(_ runGeneration: UInt64) -> Bool {
        isRunning && generation == runGeneration
    }

    private func deliver(_ event: StabilityEnvironmentEvent, generation runGeneration: UInt64) {
        guard isActive(runGeneration) else { return }
        receive?(event)
    }

    private nonisolated func deliverWorkspace(_ event: StabilityEnvironmentEvent, generation runGeneration: UInt64) {
        // nil notification queues invoke on the posting thread. Complete this
        // short handoff before willSleep returns, rather than enqueueing a Task
        // that might not run until wake. The owner never blocks on child cleanup.
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(event, generation: runGeneration) }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { deliver(event, generation: runGeneration) }
            }
        }
    }

    private nonisolated static func pathState(for path: NWPath) -> StabilityPathState {
        switch path.status {
        case .satisfied:
            return .satisfied(pathSignature(for: path))
        case .requiresConnection, .unsatisfied:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    private nonisolated static func pathSignature(for path: NWPath) -> String {
        let availableInterfaces = path.availableInterfaces
            .map { "\(interfaceTypeName($0.type)):\($0.name)" }
            .sorted()
        let usedInterfaceTypes = [
            NWInterface.InterfaceType.wifi,
            .wiredEthernet,
            .cellular,
            .loopback,
            .other
        ]
        .filter { path.usesInterfaceType($0) }
        .map(interfaceTypeName)
        .sorted()

        // NWPath exposes interface membership and types, but cannot identify every Wi-Fi AP change.
        return "available[\(availableInterfaces.joined(separator: ","))]|used[\(usedInterfaceTypes.joined(separator: ","))]"
    }

    private nonisolated static func interfaceTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .wiredEthernet:
            return "wiredEthernet"
        case .cellular:
            return "cellular"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}
