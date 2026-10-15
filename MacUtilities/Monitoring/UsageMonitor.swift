import AppKit
import Combine
import Darwin
import ServiceManagement

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

enum DataDisplayUnit: String, CaseIterable, Identifiable {
    case decimal
    case binary

    var id: String { rawValue }
    var title: String { self == .decimal ? "MB/GB" : "MiB/GiB" }
}

struct InterfaceByteCount: Codable, Equatable {
    var downloaded: UInt64
    var uploaded: UInt64
}

struct PersistedUsage: Codable {
    var schemaVersion = 2
    var localDayKey: String
    var timeZoneIdentifier: String? = TimeZone.autoupdatingCurrent.identifier
    var downloaded: UInt64 = 0
    var uploaded: UInt64 = 0
    var interfaceCounters: [String: InterfaceByteCount] = [:]
    var lastSampleDate: Date?
    var isIncomplete = true
    var incompleteReason: String?
    var history: [DailyUsageRecord]?
    var bootIdentifier: String?

    var combined: UInt64 { UsageHistory.add(downloaded, uploaded) }
}

private enum InterfaceCounterReader {
    enum ReaderError: LocalizedError {
        case sysctl(String)
        case noPhysicalInterfaces

        var errorDescription: String? {
            switch self {
            case .sysctl(let message): "Could not read network interface counters: \(message)"
            case .noPhysicalInterfaces: "No active Ethernet or Wi-Fi interface counters are available."
            }
        }
    }

    static func read() throws -> [String: InterfaceByteCount] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0

        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            throw ReaderError.sysctl(String(cString: strerror(errno)))
        }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &length, nil, 0)
        }
        guard result == 0 else {
            throw ReaderError.sysctl(String(cString: strerror(errno)))
        }

        var counters: [String: InterfaceByteCount] = [:]
        var offset = 0
        let minimumMessageSize = MemoryLayout<if_msghdr2>.size

        while offset + MemoryLayout<UInt16>.size + 2 <= length {
            let messageLength = buffer.withUnsafeBytes {
                Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            guard messageLength >= MemoryLayout<UInt16>.size + 2, offset + messageLength <= length else { break }

            let messageType = buffer[offset + 3]
            if messageType == UInt8(RTM_IFINFO2), messageLength >= minimumMessageSize {
                let message = buffer.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                if let interfaceName = name(for: message.ifm_index), isPhysicalInterface(interfaceName) {
                    counters[interfaceName] = InterfaceByteCount(
                        downloaded: message.ifm_data.ifi_ibytes,
                        uploaded: message.ifm_data.ifi_obytes
                    )
                }
            }

            offset += messageLength
        }

        guard !counters.isEmpty else { throw ReaderError.noPhysicalInterfaces }
        return counters
    }

    private static func name(for index: UInt16) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &nameBuffer) != nil else { return nil }
        return String(cString: nameBuffer)
    }

    private static func isPhysicalInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
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
        didSet { UserDefaults.standard.set(rateUnit.rawValue, forKey: Self.rateUnitKey) }
    }

    @Published var dataUnit: DataDisplayUnit {
        didSet { UserDefaults.standard.set(dataUnit.rawValue, forKey: Self.dataUnitKey) }
    }

    private static let rateUnitKey = "rateDisplayUnit"
    private static let dataUnitKey = "dataDisplayUnit"
    private let stateURL: URL
    private var persisted: PersistedUsage
    private var timer: Timer?
    private var lastRateSampleUptime: TimeInterval?
    private var lastStateWriteDate: Date?
    private let now: @MainActor () -> Date
    private let calendarProvider: @MainActor () -> Calendar
    private let readCounters: @MainActor () throws -> [String: InterfaceByteCount]
    private let boot: @MainActor () -> String

    init(stateURL: URL? = nil, startAutomatically: Bool = true,
         now: @escaping @MainActor () -> Date = Date.init,
         calendar: @escaping @MainActor () -> Calendar = { UsageHistory.calendar() },
         readCounters: @escaping @MainActor () throws -> [String: InterfaceByteCount] = InterfaceCounterReader.read,
         bootIdentifier: @escaping @MainActor () -> String = UsageMonitor.systemBootIdentifier) {
        self.now = now
        calendarProvider = calendar
        self.readCounters = readCounters
        boot = bootIdentifier
        let date = now()
        historyDate = date
        rateUnit = RateDisplayUnit(rawValue: UserDefaults.standard.string(forKey: Self.rateUnitKey) ?? "") ?? .megabitsPerSecond
        dataUnit = DataDisplayUnit(rawValue: UserDefaults.standard.string(forKey: Self.dataUnitKey) ?? "") ?? .decimal
        loginItemEnabled = SMAppService.mainApp.status == .enabled

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = supportDirectory.appendingPathComponent("MacUtilities", isDirectory: true)
        self.stateURL = stateURL ?? appDirectory.appendingPathComponent("today-usage.json")
        persisted = PersistedUsage(localDayKey: Self.localDayKey(for: date, calendar: calendar()),
                                   timeZoneIdentifier: calendar().timeZone.identifier,
                                   incompleteReason: "Collection Started After Local Midnight.", history: [])
        do {
            if let saved = try Self.readState(at: self.stateURL) {
                persisted = saved
                UsageHistory.migrate(&persisted)
            }
        } catch {
            historyWritable = false
            historyError = "Saved Usage Could Not Be Opened. The Existing File Has Been Kept."
        }
        persisted.schemaVersion = 3
        let counters = try? readCounters()
        Self.observe(at: date, calendar: calendar(), counters: counters, boot: boot(), state: &persisted)
        counterError = counters == nil ? "Device Counters Are Unavailable." : nil
        publish()
        lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        saveState(force: true)
        if startAutomatically { startSampling() }
    }

    var combinedToday: UInt64 { UsageHistory.add(downloadedToday, uploadedToday) }
    var historyCalendar: Calendar { calendarProvider() }

    var formattedDownloadRate: String { Self.formatRate(downloadBytesPerSecond, unit: rateUnit) }
    var formattedUploadRate: String { Self.formatRate(uploadBytesPerSecond, unit: rateUnit) }
    var formattedDownloadedToday: String { Self.formatData(downloadedToday, unit: dataUnit) }
    var formattedUploadedToday: String { Self.formatData(uploadedToday, unit: dataUnit) }
    var formattedCombinedToday: String { Self.formatData(combinedToday, unit: dataUnit) }

    var menuBarText: String {
        Self.formatMenuBarRates(
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            unit: rateUnit
        )
    }

    var collectionStatus: String {
        if counterError != nil { return "Monitoring Unavailable" }
        return "Device Monitoring Active"
    }

    var localTimeZoneDescription: String {
        let zone = TimeZone.autoupdatingCurrent
        return "\(zone.identifier) (\(zone.abbreviation() ?? "Local"))"
    }

    func resetToday() {
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
        guard historyWritable else { return }
        sample()
        persisted.history = []
        historyRecords = []
        saveState(force: true)
    }

    func flush() { saveState(force: true) }

    func shutdown() {
        sample()
        timer?.invalidate()
        timer = nil
        saveState(force: true)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            loginItemMessage = loginItemEnabled == enabled ? nil : "macOS Requires Approval In Login Items."
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
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
        saveState()
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
                UsageHistory.record(value, from: start, to: date, state: &state)
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
        guard historyWritable else { return }
        if !force, let lastStateWriteDate {
            let elapsed = now.timeIntervalSince(lastStateWriteDate)
            if elapsed >= 0 && elapsed < 5 { return }
        }
        do {
            try Self.saveState(persisted, at: stateURL)
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

    static func saveState(_ state: PersistedUsage, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try validate(state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func loadState(at url: URL) -> PersistedUsage? { try? readState(at: url) }

    enum StorageError: Error { case invalidSnapshot }

    static func readState(at url: URL) throws -> PersistedUsage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let maximum = 8 * 1_024 * 1_024
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw StorageError.invalidSnapshot }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(PersistedUsage.self, from: data)
        try validate(state)
        return state
    }

    static func validate(_ state: PersistedUsage) throws {
        guard (1...3).contains(state.schemaVersion), UsageHistory.validKey(state.localDayKey),
              !state.downloaded.addingReportingOverflow(state.uploaded).overflow,
              state.schemaVersion < 3 || state.history != nil,
              state.lastSampleDate?.timeIntervalSince1970.isFinite != false else {
            throw StorageError.invalidSnapshot
        }
        let records = state.history ?? []
        guard Set(records.map(\.dayKey)).count == records.count else { throw StorageError.invalidSnapshot }
        for record in records {
            guard UsageHistory.validKey(record.dayKey),
                  record.firstObservedAt.timeIntervalSince1970.isFinite,
                  record.lastObservedAt.timeIntervalSince1970.isFinite,
                  record.firstObservedAt <= record.lastObservedAt,
                  !record.downloaded.addingReportingOverflow(record.uploaded).overflow else {
                throw StorageError.invalidSnapshot
            }
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

    static func formatData(_ bytes: UInt64, unit: DataDisplayUnit) -> String {
        let base = unit == .decimal ? 1_000.0 : 1_024.0
        let mega = base * base
        let giga = mega * base
        let value = Double(bytes)
        if value >= giga {
            return String(format: "%.2f %@", locale: Locale.current, value / giga, unit == .decimal ? "GB" : "GiB")
        }
        return String(format: "%.1f %@", locale: Locale.current, value / mega, unit == .decimal ? "MB" : "MiB")
    }
}
