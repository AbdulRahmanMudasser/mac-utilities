import Foundation

nonisolated struct UsageWidgetSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var savedAt: Date
    var lastObservedAt: Date?
    var timeZoneIdentifier: String
    var dataUnit: DataDisplayUnit
    var records: [DailyUsageRecord]

    enum ValidationError: Error { case invalidProjection }

    func validate() throws {
        guard schemaVersion == 1, savedAt.timeIntervalSince1970.isFinite,
              lastObservedAt?.timeIntervalSince1970.isFinite != false,
              TimeZone(identifier: timeZoneIdentifier) != nil,
              records.count <= UsageStorageLimits.maximumRecords,
              Set(records.map(\.dayKey)).count == records.count else {
            throw ValidationError.invalidProjection
        }
        let calendar = UsageHistory.calendar(timeZone: TimeZone(identifier: timeZoneIdentifier)!)
        let endKey = UsageHistory.key(for: savedAt, calendar: calendar)
        guard let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: savedAt)) else {
            throw ValidationError.invalidProjection
        }
        let startKey = UsageHistory.key(for: start, calendar: calendar)
        for record in records {
            guard UsageHistory.validKey(record.dayKey),
                  record.dayKey >= startKey, record.dayKey <= endKey,
                  record.firstObservedAt.timeIntervalSince1970.isFinite,
                  record.lastObservedAt.timeIntervalSince1970.isFinite,
                  record.firstObservedAt <= record.lastObservedAt,
                  lastObservedAt.map({ $0 >= record.lastObservedAt }) == true,
                  !record.downloaded.addingReportingOverflow(record.uploaded).overflow else {
                throw ValidationError.invalidProjection
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard try encoder.encode(self).count <= UsageStorageLimits.maximumProjectionBytes else {
            throw ValidationError.invalidProjection
        }
    }
}
