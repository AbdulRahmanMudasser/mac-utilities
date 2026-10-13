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
    var wasPaused = false
    var isIncomplete = true
    var incompleteReason: String?

    var combined: UInt64 { downloaded &+ uploaded }
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
    @Published private(set) var isPaused = false
    @Published private(set) var isIncomplete = true
    @Published private(set) var incompleteReason: String?
    @Published private(set) var counterError: String?
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemMessage: String?

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

    init() {
        rateUnit = RateDisplayUnit(rawValue: UserDefaults.standard.string(forKey: Self.rateUnitKey) ?? "") ?? .megabitsPerSecond
        dataUnit = DataDisplayUnit(rawValue: UserDefaults.standard.string(forKey: Self.dataUnitKey) ?? "") ?? .decimal
        loginItemEnabled = SMAppService.mainApp.status == .enabled

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = supportDirectory.appendingPathComponent("MacUtilities", isDirectory: true)
        stateURL = appDirectory.appendingPathComponent("today-usage.json")

        let now = Date()
        let todayKey = Self.localDayKey(for: now)
        let currentCounters = try? InterfaceCounterReader.read()

        if let saved = Self.loadState(at: stateURL), saved.localDayKey == todayKey {
            persisted = saved
            persisted.schemaVersion = 2
            let currentTimeZone = TimeZone.autoupdatingCurrent.identifier
            Self.markTimeZoneChangeIfNeeded(currentTimeZone, state: &persisted)
            if saved.wasPaused {
                persisted.isIncomplete = true
                persisted.incompleteReason = "Monitoring Was Paused Today."
                persisted.interfaceCounters = currentCounters ?? saved.interfaceCounters
            } else if let currentCounters {
                Self.applyDelta(from: saved.interfaceCounters, to: currentCounters, in: &persisted)
                persisted.interfaceCounters = currentCounters
            } else {
                persisted.isIncomplete = true
                persisted.incompleteReason = "Device Counters Are Unavailable."
            }
        } else {
            persisted = PersistedUsage(
                localDayKey: todayKey,
                interfaceCounters: currentCounters ?? [:],
                lastSampleDate: now,
                isIncomplete: !Self.isNearLocalMidnight(now),
                incompleteReason: Self.isNearLocalMidnight(now) ? nil : "Collection Started After Local Midnight."
            )
        }

        isPaused = persisted.wasPaused
        isIncomplete = persisted.isIncomplete
        incompleteReason = persisted.incompleteReason
        downloadedToday = persisted.downloaded
        uploadedToday = persisted.uploaded
        counterError = currentCounters == nil ? "Device Counters Are Unavailable." : nil
        persisted.lastSampleDate = now
        lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        saveState(force: true)

        if !isPaused { startSampling() }
    }

    var combinedToday: UInt64 { downloadedToday &+ uploadedToday }

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
        if isPaused { return "Monitoring Paused" }
        if counterError != nil { return "Monitoring Unavailable" }
        return "Device Monitoring Active"
    }

    var localTimeZoneDescription: String {
        let zone = TimeZone.autoupdatingCurrent
        return "\(zone.identifier) (\(zone.abbreviation() ?? "Local"))"
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        persisted.wasPaused = paused
        persisted.isIncomplete = true
        persisted.incompleteReason = paused ? "Monitoring Was Paused Today." : "Collection Resumed After A Pause."
        isIncomplete = true
        incompleteReason = persisted.incompleteReason
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0

        if paused {
            timer?.invalidate()
            timer = nil
        } else {
            if let counters = try? InterfaceCounterReader.read() {
                persisted.interfaceCounters = counters
                counterError = nil
            } else {
                counterError = "Device Counters Are Unavailable."
            }
            startSampling()
        }
        saveState(force: true)
    }

    func resetToday() {
        let now = Date()
        let currentCounters = try? InterfaceCounterReader.read()
        persisted.localDayKey = Self.localDayKey(for: now)
        persisted.timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        persisted.downloaded = 0
        persisted.uploaded = 0
        persisted.interfaceCounters = currentCounters ?? [:]
        persisted.lastSampleDate = now
        lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
        persisted.isIncomplete = true
        persisted.incompleteReason = "Counters Were Reset Today."
        counterError = currentCounters == nil ? "Device Counters Are Unavailable." : nil
        downloadedToday = 0
        uploadedToday = 0
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        isIncomplete = true
        incompleteReason = persisted.incompleteReason
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

    private func sample() {
        guard !isPaused else { return }
        let now = Date()
        let timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        guard let counters = try? InterfaceCounterReader.read() else {
            counterError = "Device Counters Are Unavailable."
            persisted.isIncomplete = true
            persisted.incompleteReason = counterError
            isIncomplete = true
            incompleteReason = counterError
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
            lastRateSampleUptime = nil
            saveState()
            return
        }

        counterError = nil
        if Self.rollOverToCurrentLocalDayIfNeeded(
            at: now,
            timeZoneIdentifier: timeZoneIdentifier,
            interfaceCounters: counters,
            state: &persisted
        ) {
            downloadedToday = 0
            uploadedToday = 0
            isIncomplete = true
            incompleteReason = persisted.incompleteReason
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
            lastRateSampleUptime = ProcessInfo.processInfo.systemUptime
            saveState()
            return
        }

        Self.markTimeZoneChangeIfNeeded(timeZoneIdentifier, state: &persisted)

        let previous = persisted.interfaceCounters
        let downloadDelta = Self.applyDelta(from: previous, to: counters, in: &persisted)
        persisted.interfaceCounters = counters
        persisted.lastSampleDate = now
        downloadedToday = persisted.downloaded
        uploadedToday = persisted.uploaded
        isIncomplete = persisted.isIncomplete
        incompleteReason = persisted.incompleteReason

        let sampleUptime = ProcessInfo.processInfo.systemUptime
        if let lastRateSampleUptime {
            let elapsed = sampleUptime - lastRateSampleUptime
            if let downloadRate = Self.rateInBytesPerSecond(bytes: downloadDelta.downloaded, elapsed: elapsed),
               let uploadRate = Self.rateInBytesPerSecond(bytes: downloadDelta.uploaded, elapsed: elapsed)
            {
                downloadBytesPerSecond = downloadRate
                uploadBytesPerSecond = uploadRate
            } else {
                downloadBytesPerSecond = 0
                uploadBytesPerSecond = 0
            }
        } else {
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
        }
        lastRateSampleUptime = sampleUptime
        saveState()
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
                delta.downloaded &+= current.downloaded - previous.downloaded
            } else {
                state.isIncomplete = true
                state.incompleteReason = "An Interface Counter Reset Was Detected."
            }

            if current.uploaded >= previous.uploaded {
                delta.uploaded &+= current.uploaded - previous.uploaded
            } else {
                state.isIncomplete = true
                state.incompleteReason = "An Interface Counter Reset Was Detected."
            }
        }

        state.downloaded &+= delta.downloaded
        state.uploaded &+= delta.uploaded
        return delta
    }

    private func saveState(force: Bool = false) {
        let now = Date()
        if !force, let lastStateWriteDate, now.timeIntervalSince(lastStateWriteDate) < 5 { return }
        do {
            try Self.saveState(persisted, at: stateURL)
            lastStateWriteDate = now
        } catch {
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func loadState(at url: URL) -> PersistedUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedUsage.self, from: data)
    }

    static func localDayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    @discardableResult
    static func rollOverToCurrentLocalDayIfNeeded(
        at date: Date,
        timeZoneIdentifier: String,
        interfaceCounters: [String: InterfaceByteCount],
        state: inout PersistedUsage,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let currentDayKey = localDayKey(for: date, calendar: calendar)
        guard state.localDayKey != currentDayKey else { return false }
        state = PersistedUsage(
            localDayKey: currentDayKey,
            timeZoneIdentifier: timeZoneIdentifier,
            interfaceCounters: interfaceCounters,
            lastSampleDate: date,
            wasPaused: false,
            isIncomplete: true,
            incompleteReason: "The Local-Day Boundary Was Sampled Between Intervals."
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

    static func isNearLocalMidnight(_ date: Date) -> Bool {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: date)
        return date.timeIntervalSince(start) < 2
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
