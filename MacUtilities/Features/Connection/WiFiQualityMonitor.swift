import Combine
import Foundation

@MainActor
final class WiFiQualityMonitor: ObservableObject {
    @Published private(set) var snapshot: WiFiQualitySnapshot?
    @Published private(set) var isRefreshing = false
    private(set) var isVisible = false

    private let reader: any WiFiQualityReading
    private let refreshInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pollingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var hasShutDown = false

    init(
        reader: any WiFiQualityReading = CoreWLANWiFiQualityReader(),
        refreshInterval: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.reader = reader
        self.refreshInterval = refreshInterval
        self.sleep = sleep
    }

    func setVisible(_ visible: Bool) {
        guard !hasShutDown, isVisible != visible else { return }
        isVisible = visible
        generation &+= 1
        pollingTask?.cancel()

        guard visible else {
            isRefreshing = false
            return
        }

        snapshot = nil
        isRefreshing = true
        startPollingIfNeeded()
    }

    func refreshAfterWake(isVisible visible: Bool) {
        guard !hasShutDown else { return }
        isVisible = visible
        generation &+= 1
        pollingTask?.cancel()

        guard visible else {
            isRefreshing = false
            return
        }

        snapshot = nil
        isRefreshing = true
        startPollingIfNeeded()
    }

    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        isVisible = false
        generation &+= 1
        pollingTask?.cancel()
        snapshot = nil
        isRefreshing = false
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil, isVisible, !hasShutDown else { return }
        let currentGeneration = generation
        pollingTask = Task { [weak self] in
            await self?.poll(generation: currentGeneration)
        }
    }

    private func poll(generation currentGeneration: UInt64) async {
        while shouldPoll(generation: currentGeneration) {
            isRefreshing = true
            let next = await reader.read()
            guard shouldPoll(generation: currentGeneration) else { break }

            if let previous = snapshot, previous.interfaceName != next.interfaceName {
                snapshot = nil
            }
            snapshot = next
            isRefreshing = false

            do {
                try await sleep(refreshInterval)
            } catch {
                break
            }
        }

        pollingTask = nil
        if isVisible && !hasShutDown {
            isRefreshing = true
            startPollingIfNeeded()
        } else {
            isRefreshing = false
        }
    }

    private func shouldPoll(generation currentGeneration: UInt64) -> Bool {
        isVisible && !hasShutDown && generation == currentGeneration && !Task.isCancelled
    }
}
