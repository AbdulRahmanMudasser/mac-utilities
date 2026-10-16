import Foundation

nonisolated enum UsageWidgetSnapshotReader {
    enum ReadError: Error { case unsupportedEnvelope, missingProjection, oversizedEnvelope }

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let widgetSnapshot: UsageWidgetSnapshot?
    }

    static func read(at url: URL) throws -> UsageWidgetSnapshot {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: UsageStorageLimits.maximumEnvelopeBytes + 1) ?? Data()
        guard data.count <= UsageStorageLimits.maximumEnvelopeBytes else { throw ReadError.oversizedEnvelope }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> UsageWidgetSnapshot {
        guard data.count <= UsageStorageLimits.maximumEnvelopeBytes else { throw ReadError.oversizedEnvelope }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 3 else { throw ReadError.unsupportedEnvelope }
        guard let snapshot = envelope.widgetSnapshot else { throw ReadError.missingProjection }
        try snapshot.validate()
        return snapshot
    }
}
