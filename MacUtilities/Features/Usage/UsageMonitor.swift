import Foundation
import Combine
import Darwin

enum RateDisplayUnit: String, CaseIterable, Identifiable {
    case megabitsPerSecond
    case megabytesPerSecond

    var id: String { rawValue }
    var title: String {
        switch self {
        case .megabitsPerSecond: "Mbps"
        case .megabytesPerSecond: "MB/s"
        }
    }
}

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var downloadedToday: UInt64 = 0
    @Published private(set) var uploadedToday: UInt64 = 0
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var uploadBytesPerSecond: Double = 0
    @Published private(set) var isIncomplete = true
    @Published private(set) var incompleteReason: String?
    @Published private(set) var counterError: String?
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var historyRecords: [DailyUsageRecord] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyWritable = true
    @Published private(set) var historyDate: Date

    @Published var rateUnit: RateDisplayUnit {
        didSet { preferences.set(rateUnit.rawValue, forKey: Self.rateUnitKey) }
    }

    @Published var dataUnit: DataDisplayUnit {
        didSet {
            preferences.set(dataUnit.rawValue, forKey: Self.dataUnitKey)
            guard oldValue != dataUnit else { return }
            requestImmediateSnapshotCommit(.dataUnitChanged)
            saveState(force: true)
        }
    }

    private static let rateUnitKey = "rateDisplayUnit"
    private static let dataUnitKey = "dataDisplayUnit"
    private var store: UsageStateStore?
    private var storageReady = false
    private var canSample = false
    private let loginItems: LoginItemService
    private let preferences: UserDefaults
    var onSnapshotCommitted: ((UsageWidgetSnapshot) -> Void)?
    var onSnapshotCommittedWithReason: ((UsageWidgetSnapshot, WidgetReloadReason) -> Void)?
    private var pendingSnapshotCommitReason: WidgetReloadReason?
    private var lastCommittedWidgetRecords: [DailyUsageRecord]?
    private var persisted: PersistedUsage
    private var timer: Timer?
    private var lastRateSampleUptime: TimeInterval?
    private var lastStateWriteDate: Date?
    private let now: @MainActor () -> Date
    private let calendarProvider: @MainActor () -> Calendar
    private let readCounters: @MainActor () throws -> [String: InterfaceByteCount]
    private let boot: @MainActor () -> String

    init(stateURL: URL? = nil, startAutomatically: Bool = true,
         stateStore: UsageStateStore? = nil, loginItems: LoginItemService? = nil,
         preferences: UserDefaults? = nil,
         storagePaths: UsageStoragePaths? = nil,
         onSnapshotCommittedWithReason: ((UsageWidgetSnapshot, WidgetReloadReason) -> Void)? = nil,
         now: @escaping @MainActor () -> Date = Date.init,
         calendar: @escaping @MainActor () -> Calendar = { UsageHistory.calendar() },
         readCounters: @escaping @MainActor () throws -> [String: InterfaceByteCount] = InterfaceCounterReader.read,
         bootIdentifier: @escaping @MainActor () -> String = UsageMonitor.systemBootIdentifier) {
        self.onSnapshotCommittedWithReason = onSnapshotCommittedWithReason
        self.now = now
        calendarProvider = calendar
        self.readCounters = readCounters
        boot = bootIdentifier
        let isolated = stateURL != nil || stateStore != nil || storagePaths != nil ||
            !(Bundle.main.object(forInfoDictionaryKey: "MACUTILITIES_VERIFICATION_NAMESPACE") as? String ?? "").isEmpty
        let preferences = preferences ?? (isolated ? UserDefaults(suiteName: "MacUtilities.Verification.\(UUID().uuidString)")! : .standard)
        self.preferences = preferences
        let date = now()
        historyDate = date
        rateUnit = RateDisplayUnit(rawValue: preferences.string(forKey: Self.rateUnitKey) ?? "") ?? .megabitsPerSecond
        dataUnit = DataDisplayUnit(rawValue: preferences.string(forKey: Self.dataUnitKey) ?? "") ?? .decimal
        self.loginItems = loginItems ?? (isolated ? .isolated : .system)
        loginItemEnabled = self.loginItems.isEnabled
        persisted = PersistedUsage(localDayKey: Self.localDayKey(for: date, calendar: calendar()),
                                   timeZoneIdentifier: calendar().timeZone.identifier,
                                   incompleteReason: "Collection Started After Local Midnight.", history: [])
        var verification = false
        do {
            let selectedStore: UsageStateStore
            if let stateStore {
                selectedStore = stateStore
            } else if let stateURL {
                selectedStore = UsageStateStore(stateURL: stateURL, acquireLease: false)
            } else {
                let paths = try storagePaths ?? UsageStoragePaths.resolve()
                verification = paths.isVerification
                selectedStore = UsageStateStore(stateURL: paths.stateURL)
            }
            store = selectedStore
            if let saved = try selectedStore.load() {
                persisted = saved
                UsageAccounting.migrate(&persisted)
            }
            storageReady = true
            canSample = !verification
        } catch {
            historyWritable = false
            historyError = "Saved Usage Could Not Be Opened. " + error.localizedDescription
            counterError = "Usage Storage Is Unavailable."
        }
        lastCommittedWidgetRecords = persisted.widgetSnapshot?.records
        let savedDay = persisted.localDayKey
        let savedZone = persisted.timeZoneIdentifier
        let savedUnit = persisted.widgetSnapshot?.dataUnit
        persisted.schemaVersion = 3
        if canSample {
            let counters = try? readCounters()
            Self.observe(at: date, calendar: calendar(), counters: counters, boot: boot(), state: &persisted)
            counterError = counters == nil ? "Device Counters Are Unavailable." : nil
            lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        }
        publish()
        if savedDay != persisted.localDayKey {
            requestImmediateSnapshotCommit(.localDayChanged)
        } else if savedZone != persisted.timeZoneIdentifier {
            requestImmediateSnapshotCommit(.timeZoneChanged)
        } else if savedUnit != nil && savedUnit != dataUnit {
            requestImmediateSnapshotCommit(.dataUnitChanged)
        }
        if canSample { saveState(force: true) }
        if startAutomatically && canSample { startSampling() }
    }

    var combinedToday: UInt64 { UsageHistory.add(downloadedToday, uploadedToday) }
    var historyCalendar: Calendar { calendarProvider() }

    var formattedDownloadRate: String { Self.formatRate(downloadBytesPerSecond, unit: rateUnit) }
    var formattedUploadRate: String { Self.formatRate(uploadBytesPerSecond, unit: rateUnit) }
    var formattedDownloadedToday: String { UsageFormatting.data(downloadedToday, unit: dataUnit) }
    var formattedUploadedToday: String { UsageFormatting.data(uploadedToday, unit: dataUnit) }
    var formattedCombinedToday: String { UsageFormatting.data(combinedToday, unit: dataUnit) }

    var menuBarText: String {
        Self.formatMenuBarRates(
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            unit: rateUnit
        )
    }

    var isMonitoringActive: Bool { storageReady && canSample && counterError == nil }

    var collectionStatus: String {
        if !isMonitoringActive { return "Monitoring Unavailable" }
        return "Device Monitoring Active"
    }

    var localTimeZoneDescription: String {
        let zone = TimeZone.autoupdatingCurrent
        return "\(zone.identifier) (\(zone.abbreviation() ?? "Local"))"
    }

    func resetToday() {
        guard canSample else { return }
        sample()
        persisted.downloaded = 0
        persisted.uploaded = 0
        lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        persisted.isIncomplete = true
        persisted.incompleteReason = "Counters Were Reset Today."
        downloadedToday = 0
        uploadedToday = 0
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        isIncomplete = true
        incompleteReason = persisted.incompleteReason
        saveState(force: true)
    }

    func clearHistory() {
        guard historyWritable && canSample else { return }
        sample()
        persisted.history = []
        historyRecords = []
        requestImmediateSnapshotCommit(.historyCleared)
        saveState(force: true)
    }

    func flush() { saveState(force: true) }

    func shutdown() {
        sample()
        timer?.invalidate()
        timer = nil
        saveState(force: true)
        canSample = false
        store?.close()
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            loginItemEnabled = try loginItems.setEnabled(enabled)
            loginItemMessage = loginItemEnabled == enabled ? nil : "macOS Requires Approval In Login Items."
        } catch {
            loginItemEnabled = loginItems.isEnabled
            loginItemMessage = error.localizedDescription
        }
    }

    private func startSampling() {
        guard timer == nil else { return }
        lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        let samplingTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        samplingTimer.tolerance = 0.15
        RunLoop.main.add(samplingTimer, forMode: .common)
        timer = samplingTimer
    }

    func sample() {
        guard canSample else { return }
        let previousDay = persisted.localDayKey
        let previousZone = persisted.timeZoneIdentifier
        let date = now()
        let counters = try? readCounters()
        let delta = Self.observe(at: date, calendar: calendarProvider(), counters: counters,
                                 boot: boot(), state: &persisted)
        historyDate = date
        counterError = counters == nil ? "Device Counters Are Unavailable." : nil
        publish()
        let uptime = ProcessInfo.processInfo.systemUptime
        if let previous = lastRateSampleUptime, let delta {
            downloadBytesPerSecond = Self.rateInBytesPerSecond(bytes: delta.downloaded, elapsed: uptime - previous) ?? 0
            uploadBytesPerSecond = Self.rateInBytesPerSecond(bytes: delta.uploaded, elapsed: uptime - previous) ?? 0
        } else {
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
        }
        lastRateSampleUptime = counters == nil ? nil : uptime
        let dayChanged = previousDay != persisted.localDayKey
        let timeZoneChanged = previousZone != persisted.timeZoneIdentifier
        if dayChanged {
            requestImmediateSnapshotCommit(.localDayChanged)
        } else if timeZoneChanged {
            requestImmediateSnapshotCommit(.timeZoneChanged)
        }
        saveState(force: dayChanged || timeZoneChanged)
    }

    private func publish() {
        downloadedToday = persisted.downloaded
        uploadedToday = persisted.uploaded
        isIncomplete = persisted.isIncomplete
        incompleteReason = persisted.incompleteReason
        if historyRecords != (persisted.history ?? []) { historyRecords = persisted.history ?? [] }
    }

    @discardableResult
    static func observe(at date: Date, calendar: Calendar, counters: [String: InterfaceByteCount]?,
                        boot: String, state: inout PersistedUsage) -> InterfaceByteCount? {
        let zone = calendar.timeZone.identifier
        let dayChanged = rollOverToCurrentLocalDayIfNeeded(at: date, timeZoneIdentifier: zone,
            interfaceCounters: [:], state: &state, calendar: calendar)
        let zoneChanged = markTimeZoneChangeIfNeeded(zone, state: &state)
        let start = state.lastSampleDate
        let comparable = !dayChanged && !zoneChanged && state.bootIdentifier == boot && !boot.isEmpty
            && start != nil && date > start! && !state.interfaceCounters.isEmpty
        state.bootIdentifier = boot
        guard let counters else {
            state.interfaceCounters = [:]
            state.lastSampleDate = nil
            state.isIncomplete = true
            state.incompleteReason = "Device Counters Are Unavailable."
            return nil
        }
        var delta: InterfaceByteCount?
        if comparable, let start {
            let previous = state.interfaceCounters
            let value = applyDelta(from: previous, to: counters, in: &state)
            // Long intervals are observed totals, not a claim of uninterrupted sampling.
            if date.timeIntervalSince(start) > 2.5 { state.isIncomplete = true }
            let hasObservedDirection = counters.contains { name, current in
                guard let old = previous[name] else { return false }
                return current.downloaded >= old.downloaded || current.uploaded >= old.uploaded
            }
            if hasObservedDirection {
                UsageAccounting.record(value, from: start, to: date, state: &state)
                delta = value
            }
        } else {
            state.isIncomplete = true
        }
        state.interfaceCounters = counters
        state.lastSampleDate = date
        return delta
    }

    static func systemBootIdentifier() -> String {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "" }
        return "\(value.tv_sec).\(value.tv_usec)"
    }

    @discardableResult
    static func applyDelta(
        from old: [String: InterfaceByteCount],
        to new: [String: InterfaceByteCount],
        in state: inout PersistedUsage
    ) -> InterfaceByteCount {
        var delta = InterfaceByteCount(downloaded: 0, uploaded: 0)
        let oldNames = Set(old.keys)
        let newNames = Set(new.keys)

        if oldNames != newNames {
            state.isIncomplete = true
            state.incompleteReason = "A Network Interface Changed During Collection."
        }

        for (name, current) in new {
            guard let previous = old[name] else { continue }
            if current.downloaded >= previous.downloaded {
                delta.downloaded = UsageHistory.add(delta.downloaded, current.downloaded - previous.downloaded)
            } else {
                state.isIncomplete = true
                state.incompleteReason = "An Interface Counter Reset Was Detected."
            }

            if current.uploaded >= previous.uploaded {
                delta.uploaded = UsageHistory.add(delta.uploaded, current.uploaded - previous.uploaded)
            } else {
                state.isIncomplete = true
                state.incompleteReason = "An Interface Counter Reset Was Detected."
            }
        }

        delta = UsageHistory.accumulating(delta, into: InterfaceByteCount(downloaded: 0, uploaded: 0))
        let total = UsageHistory.accumulating(delta, into: InterfaceByteCount(downloaded: state.downloaded, uploaded: state.uploaded))
        state.downloaded = total.downloaded
        state.uploaded = total.uploaded
        return delta
    }

    private func saveState(force: Bool = false) {
        let now = now()
        guard historyWritable, canSample, let store else { return }
        if !force, let lastStateWriteDate {
            let elapsed = now.timeIntervalSince(lastStateWriteDate)
            if elapsed >= 0 && elapsed < 5 { return }
        }
        do {
            persisted.widgetSnapshot = try UsageSnapshotPublisher.snapshot(for: persisted, at: now, unit: dataUnit, calendar: calendarProvider())
            try store.save(persisted)
            if let snapshot = persisted.widgetSnapshot {
                let reason = pendingSnapshotCommitReason ?? .ordinary
                let shouldNotifyReasonedCommit = reason.isImmediate || lastCommittedWidgetRecords != snapshot.records
                lastCommittedWidgetRecords = snapshot.records
                pendingSnapshotCommitReason = nil
                onSnapshotCommitted?(snapshot)
                if shouldNotifyReasonedCommit {
                    onSnapshotCommittedWithReason?(snapshot, reason)
                }
            }
            lastStateWriteDate = now
            historyError = nil
        } catch {
            historyError = "Usage Could Not Be Saved. We Will Try Again."
            persisted.isIncomplete = true
            persisted.incompleteReason = "Today's Usage Could Not Be Saved Locally."
            isIncomplete = true
            incompleteReason = persisted.incompleteReason
        }
    }

    private func requestImmediateSnapshotCommit(_ reason: WidgetReloadReason) {
        if pendingSnapshotCommitReason == nil {
            pendingSnapshotCommitReason = reason
        }
    }

    static func localDayKey(for date: Date, calendar: Calendar = UsageHistory.calendar()) -> String {
        UsageHistory.key(for: date, calendar: calendar)
    }

    @discardableResult
    static func rollOverToCurrentLocalDayIfNeeded(
        at date: Date,
        timeZoneIdentifier: String,
        interfaceCounters: [String: InterfaceByteCount],
        state: inout PersistedUsage,
        calendar: Calendar = UsageHistory.calendar()
    ) -> Bool {
        let currentDayKey = localDayKey(for: date, calendar: calendar)
        guard state.localDayKey != currentDayKey else { return false }
        let history = state.history
        let boot = state.bootIdentifier
        state = PersistedUsage(
            schemaVersion: state.schemaVersion,
            localDayKey: currentDayKey,
            timeZoneIdentifier: timeZoneIdentifier,
            interfaceCounters: interfaceCounters,
            lastSampleDate: nil,
            isIncomplete: true,
            incompleteReason: "The Local-Day Boundary Was Sampled Between Intervals.",
            history: history, bootIdentifier: boot
        )
        return true
    }

    @discardableResult
    static func markTimeZoneChangeIfNeeded(_ timeZoneIdentifier: String, state: inout PersistedUsage) -> Bool {
        guard let previousTimeZoneIdentifier = state.timeZoneIdentifier else {
            state.timeZoneIdentifier = timeZoneIdentifier
            migrateLegacyTimeZoneWarning(in: &state)
            return false
        }

        guard previousTimeZoneIdentifier != timeZoneIdentifier else {
            migrateLegacyTimeZoneWarning(in: &state)
            return false
        }

        state.timeZoneIdentifier = timeZoneIdentifier
        state.isIncomplete = true
        state.incompleteReason = "The Local Time Zone Changed During Collection."
        return true
    }

    private static func migrateLegacyTimeZoneWarning(in state: inout PersistedUsage) {
        let obsoleteWarnings = [
            "The Local Time Zone Changed Or Was Previously Unknown.",
            "Today's Usage May Be Partial Because The Previous Local Time Zone Could Not Be Verified."
        ]
        guard let reason = state.incompleteReason, obsoleteWarnings.contains(reason) else { return }
        state.isIncomplete = true
        state.incompleteReason = "Today's Usage Includes An Incomplete Previous Collection."
    }

    static func rateInBytesPerSecond(bytes: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, elapsed <= 2.5 else { return nil }
        return Double(bytes) / elapsed
    }

    static func formatRate(_ bytesPerSecond: Double, unit: RateDisplayUnit) -> String {
        "\(formatRateAmount(bytesPerSecond, unit: unit)) \(unit.title)"
    }

    static func formatMenuBarRates(
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        unit: RateDisplayUnit
    ) -> String {
        let download = formatRateAmount(downloadBytesPerSecond, unit: unit)
        let upload = formatRateAmount(uploadBytesPerSecond, unit: unit)
        return "↓ \(download) / ↑ \(upload) \(unit.title)"
    }

    private static func formatRateAmount(_ bytesPerSecond: Double, unit: RateDisplayUnit) -> String {
        let amount = unit == .megabitsPerSecond ? bytesPerSecond * 8 / 1_000_000 : bytesPerSecond / 1_000_000
        return String(format: "%.1f", locale: Locale.current, amount)
    }

}
