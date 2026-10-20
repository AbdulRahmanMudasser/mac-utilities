import Foundation

enum WidgetReloadReason: Equatable, Sendable {
    case ordinary
    case historyCleared
    case dataUnitChanged
    case localDayChanged
    case timeZoneChanged

    var isImmediate: Bool {
        switch self {
        case .ordinary: false
        case .historyCleared, .dataUnitChanged, .localDayChanged, .timeZoneChanged: true
        }
    }
}

@MainActor
final class WidgetReloadCoordinator {
    typealias ScheduledCancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> ScheduledCancellation

    private let widgetKind: String
    private let minimumInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let reloadTimelines: @MainActor (String) -> Void
    private let schedule: Scheduler
    private var lastReloadAt: Date?
    private var hasPendingOrdinaryReload = false
    private var cancelScheduledReload: ScheduledCancellation?
    private var isShutdown = false

    init(
        widgetKind: String,
        minimumInterval: TimeInterval = 30 * 60,
        now: @escaping @MainActor () -> Date = Date.init,
        reloadTimelines: @escaping @MainActor (String) -> Void,
        schedule: @escaping Scheduler = WidgetReloadCoordinator.scheduleOnMainRunLoop
    ) {
        self.widgetKind = widgetKind
        self.minimumInterval = max(0, minimumInterval)
        self.now = now
        self.reloadTimelines = reloadTimelines
        self.schedule = schedule
    }

    func requestReload(for reason: WidgetReloadReason) {
        guard !isShutdown else { return }
        let date = now()
        if reason.isImmediate {
            cancelPendingOrdinaryReload()
            reload(at: date)
            return
        }

        guard let lastReloadAt else {
            reload(at: date)
            return
        }
        let elapsed = date.timeIntervalSince(lastReloadAt)
        guard elapsed >= minimumInterval else {
            hasPendingOrdinaryReload = true
            schedulePendingReload(after: max(0, minimumInterval - elapsed))
            return
        }
        cancelPendingOrdinaryReload()
        reload(at: date)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelPendingOrdinaryReload()
    }

    private func schedulePendingReload(after delay: TimeInterval) {
        guard cancelScheduledReload == nil else { return }
        cancelScheduledReload = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelScheduledReload = nil
            self.firePendingReloadIfDue()
        }
    }

    private func firePendingReloadIfDue() {
        guard !isShutdown, hasPendingOrdinaryReload else { return }
        let date = now()
        guard let lastReloadAt else {
            hasPendingOrdinaryReload = false
            reload(at: date)
            return
        }
        let remaining = minimumInterval - date.timeIntervalSince(lastReloadAt)
        guard remaining <= 0 else {
            schedulePendingReload(after: remaining)
            return
        }
        hasPendingOrdinaryReload = false
        reload(at: date)
    }

    private func reload(at date: Date) {
        lastReloadAt = date
        reloadTimelines(widgetKind)
    }

    private func cancelPendingOrdinaryReload() {
        hasPendingOrdinaryReload = false
        cancelScheduledReload?()
        cancelScheduledReload = nil
    }

    static func scheduleOnMainRunLoop(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> ScheduledCancellation {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            MainActor.assumeIsolated { operation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
