import Darwin
import Foundation

nonisolated struct PersistedUsage: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var localDayKey: String
    var timeZoneIdentifier: String?
    var downloaded: UInt64
    var uploaded: UInt64
    var interfaceCounters: [String: InterfaceByteCount]
    var lastSampleDate: Date?
    var isIncomplete: Bool
    var incompleteReason: String?
    var history: [DailyUsageRecord]?
    var bootIdentifier: String?
    var widgetSnapshot: UsageWidgetSnapshot?

    init(
        schemaVersion: Int = 2,
        localDayKey: String,
        timeZoneIdentifier: String? = TimeZone.autoupdatingCurrent.identifier,
        downloaded: UInt64 = 0,
        uploaded: UInt64 = 0,
        interfaceCounters: [String: InterfaceByteCount] = [:],
        lastSampleDate: Date? = nil,
        isIncomplete: Bool = true,
        incompleteReason: String? = nil,
        history: [DailyUsageRecord]? = nil,
        bootIdentifier: String? = nil,
        widgetSnapshot: UsageWidgetSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.localDayKey = localDayKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.interfaceCounters = interfaceCounters
        self.lastSampleDate = lastSampleDate
        self.isIncomplete = isIncomplete
        self.incompleteReason = incompleteReason
        self.history = history
        self.bootIdentifier = bootIdentifier
        self.widgetSnapshot = widgetSnapshot
    }

    var combined: UInt64 { UsageHistory.add(downloaded, uploaded) }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case localDayKey
        case timeZoneIdentifier
        case downloaded
        case uploaded
        case interfaceCounters
        case lastSampleDate
        case isIncomplete
        case incompleteReason
        case history
        case bootIdentifier
        case widgetSnapshot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        localDayKey = try values.decode(String.self, forKey: .localDayKey)
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        downloaded = try values.decode(UInt64.self, forKey: .downloaded)
        uploaded = try values.decode(UInt64.self, forKey: .uploaded)
        interfaceCounters = try values.decode([String: InterfaceByteCount].self, forKey: .interfaceCounters)
        lastSampleDate = try values.decodeIfPresent(Date.self, forKey: .lastSampleDate)
        isIncomplete = try values.decode(Bool.self, forKey: .isIncomplete)
        incompleteReason = try values.decodeIfPresent(String.self, forKey: .incompleteReason)
        history = try values.decodeIfPresent([DailyUsageRecord].self, forKey: .history)
        bootIdentifier = try values.decodeIfPresent(String.self, forKey: .bootIdentifier)

        // The projection is derived data. A malformed or future projection must not
        // prevent otherwise valid accounting fields from being recovered.
        widgetSnapshot = try? values.decode(UsageWidgetSnapshot.self, forKey: .widgetSnapshot)
    }
}

@MainActor
final class UsageStateStore {
    nonisolated enum StorageError: Error, LocalizedError {
        case invalidSnapshot
        case unsupportedSchema(Int)
        case alreadyRunning
        case loadRequired
        case closed

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                "The saved usage file is invalid or exceeds the supported size. It has been kept."
            case .unsupportedSchema(let version):
                "The saved usage file uses unsupported schema version \(version). It has been kept."
            case .alreadyRunning:
                "Another Mac Utilities instance already owns the usage history."
            case .loadRequired:
                "Usage storage must load successfully before it can be written."
            case .closed:
                "Usage storage has been closed and cannot be used again."
            }
        }
    }

    let stateURL: URL
    private let acquireLease: Bool
    private var lease: UsageWriterLease?
    private var loadSucceeded = false
    private var loadFailed = false
    private var isClosed = false

    init(
        stateURL: URL,
        acquireLease: Bool = true
    ) {
        self.stateURL = stateURL
        self.acquireLease = acquireLease
    }

    func load() throws -> PersistedUsage? {
        loadSucceeded = false
        loadFailed = false
        do {
            try ensureLease()
            let state = try Self.readState(at: stateURL)
            loadSucceeded = true
            return state
        } catch {
            loadFailed = true
            throw error
        }
    }

    func save(_ state: PersistedUsage) throws {
        guard !isClosed else { throw StorageError.closed }
        guard loadSucceeded, !loadFailed else { throw StorageError.loadRequired }
        try ensureLease()
        try Self.saveState(state, at: stateURL)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        loadSucceeded = false
        loadFailed = true
        lease?.close()
        lease = nil
    }

    private func ensureLease() throws {
        guard !isClosed else { throw StorageError.closed }
        guard acquireLease, lease == nil else { return }
        do {
            lease = try UsageWriterLease(url: Self.leaseURL(for: stateURL))
        } catch UsageWriterLease.LeaseError.alreadyLocked {
            throw StorageError.alreadyRunning
        }
    }

    nonisolated static func readState(at url: URL) throws -> PersistedUsage? {
        guard try pathExists(at: url) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: UsageStorageLimits.maximumEnvelopeBytes + 1) ?? Data()
        guard data.count <= UsageStorageLimits.maximumEnvelopeBytes else { throw StorageError.invalidSnapshot }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(PersistedUsage.self, from: data)
        try validateCore(state)
        if let projection = state.widgetSnapshot {
            do {
                try validateProjection(projection)
                try validateProjectionHistory(projection, state: state)
            } catch {
                state.widgetSnapshot = nil
            }
        }
        return state
    }

    nonisolated static func saveState(_ state: PersistedUsage, at url: URL) throws {
        try validate(state)
        let data = try encoded(state)
        guard data.count <= UsageStorageLimits.maximumEnvelopeBytes else { throw StorageError.invalidSnapshot }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func validate(_ state: PersistedUsage) throws {
        try validateCore(state)
        if let projection = state.widgetSnapshot {
            try validateProjection(projection)
            try validateProjectionHistory(projection, state: state)
        }
    }

    nonisolated static func validateCore(_ state: PersistedUsage) throws {
        guard state.schemaVersion >= 1 else { throw StorageError.invalidSnapshot }
        guard state.schemaVersion <= 3 else { throw StorageError.unsupportedSchema(state.schemaVersion) }
        guard UsageHistory.validKey(state.localDayKey),
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

    nonisolated static func validateProjection(_ projection: UsageWidgetSnapshot) throws {
        try projection.validate()
    }

    nonisolated private static func validateProjectionHistory(_ projection: UsageWidgetSnapshot, state: PersistedUsage) throws {
        let expected = try UsageSnapshotPublisher.snapshot(for: state, at: projection.savedAt,
            unit: projection.dataUnit,
            calendar: UsageHistory.calendar(timeZone: TimeZone(identifier: projection.timeZoneIdentifier)!))
        guard projection == expected else {
            throw StorageError.invalidSnapshot
        }
    }

    nonisolated static func encoded(_ state: PersistedUsage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    nonisolated static func fileExists(at url: URL) -> Bool {
        (try? pathExists(at: url)) == true
    }

    nonisolated static func pathExists(at url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { path in lstat(path, &info) }
        guard result != 0 else { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    nonisolated static func leaseURL(for stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("usage-writer.lock", isDirectory: false)
    }
}
