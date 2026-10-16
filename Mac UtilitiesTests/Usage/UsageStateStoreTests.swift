import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct UsageStateStoreTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        var stateURL: URL { directory.appendingPathComponent("today-usage.json") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-state-store-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func state(day: String = "2026-10-17") -> PersistedUsage {
        PersistedUsage(schemaVersion: 3, localDayKey: day, timeZoneIdentifier: "GMT", history: [])
    }

    private func snapshot(at date: Date) -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(savedAt: date, lastObservedAt: nil, timeZoneIdentifier: "GMT",
            dataUnit: .decimal, records: [])
    }

    private func encodedState(ofSize targetSize: Int) throws -> PersistedUsage {
        var value = state()
        value.incompleteReason = ""
        let base = try UsageStateStore.encoded(value).count
        #expect(base <= targetSize)
        value.incompleteReason = String(repeating: "x", count: targetSize - base)
        #expect(try UsageStateStore.encoded(value).count == targetSize)
        return value
    }

    @Test
    func missingStateLoadsAsNilAndValidStateRoundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = UsageStateStore(stateURL: fixture.stateURL, acquireLease: false)

        #expect(try store.load() == nil)
        let value = state()
        try store.save(value)
        #expect(try UsageStateStore.readState(at: fixture.stateURL) == value)
        store.close()
    }

    @Test(arguments: ["malformed-object", "unknown-projection-version"])
    func invalidOptionalProjectionDoesNotDiscardValidCore(_ kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = state()
        var json = try #require(JSONSerialization.jsonObject(with: UsageStateStore.encoded(value)) as? [String: Any])
        json["widgetSnapshot"] = kind == "malformed-object"
            ? "not a projection"
            : ["schemaVersion": 99]
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.stateURL)

        let loaded = try #require(try UsageStateStore.readState(at: fixture.stateURL))
        #expect(loaded.localDayKey == value.localDayKey)
        #expect(loaded.history == [])
        #expect(loaded.widgetSnapshot == nil)
    }

    @Test(arguments: ["schemaVersion", "downloaded", "uploaded", "interfaceCounters", "isIncomplete"])
    func missingRequiredCoreFieldIsNotDefaulted(_ missingField: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var json = try #require(JSONSerialization.jsonObject(with: UsageStateStore.encoded(state())) as? [String: Any])
        json.removeValue(forKey: missingField)
        let invalidBytes = try JSONSerialization.data(withJSONObject: json)
        try invalidBytes.write(to: fixture.stateURL)

        #expect(throws: (any Error).self) { try UsageStateStore.readState(at: fixture.stateURL) }
        #expect(try Data(contentsOf: fixture.stateURL) == invalidBytes)
    }

    @Test
    func competingStoreCannotLoadUntilCurrentLeaseCloses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = UsageStateStore(stateURL: fixture.stateURL)
        let second = UsageStateStore(stateURL: fixture.stateURL)
        #expect(try first.load() == nil)
        #expect(throws: (any Error).self) { try second.load() }
        first.close()
        #expect(throws: (any Error).self) { try first.load() }
        #expect(try second.load() == nil)
        second.close()
    }

    @Test
    func closedStoreCannotWriteOrReacquireItsReleasedLease() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = UsageStateStore(stateURL: fixture.stateURL, acquireLease: true)
        #expect(try store.load() == nil)
        store.close()

        #expect(throws: (any Error).self) { try store.save(state()) }
        #expect(!UsageStateStore.fileExists(at: fixture.stateURL))
    }

    @Test
    func validEightMiBLegacyEnvelopeRemainsReadableAndCanCarryProjection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacyBoundary = try encodedState(ofSize: 8 * 1_024 * 1_024)
        let originalData = try UsageStateStore.encoded(legacyBoundary)
        try originalData.write(to: fixture.stateURL)
        #expect(try UsageStateStore.readState(at: fixture.stateURL) == legacyBoundary)

        var projected = legacyBoundary
        projected.widgetSnapshot = snapshot(at: ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!)
        try UsageStateStore.saveState(projected, at: fixture.stateURL)
        let savedData = try Data(contentsOf: fixture.stateURL)
        #expect(savedData.count > 8 * 1_024 * 1_024)
        #expect(savedData.count <= UsageStorageLimits.maximumEnvelopeBytes)
        #expect(try UsageStateStore.readState(at: fixture.stateURL) == projected)
    }

    @Test
    func exactNewEnvelopeLimitRemainsReadable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let boundary = try encodedState(ofSize: UsageStorageLimits.maximumEnvelopeBytes)
        try UsageStateStore.saveState(boundary, at: fixture.stateURL)
        #expect(try UsageStateStore.readState(at: fixture.stateURL) == boundary)
    }

    @Test
    func oversizedWriteIsRejectedWithoutReplacingLastGoodFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let good = state()
        try UsageStateStore.saveState(good, at: fixture.stateURL)
        let originalData = try Data(contentsOf: fixture.stateURL)
        let tooLarge = try encodedState(ofSize: UsageStorageLimits.maximumEnvelopeBytes + 1)

        #expect(throws: (any Error).self) { try UsageStateStore.saveState(tooLarge, at: fixture.stateURL) }
        #expect(try Data(contentsOf: fixture.stateURL) == originalData)
        #expect(try UsageStateStore.readState(at: fixture.stateURL) == good)
    }

    @Test
    func failedFilesystemWritePreservesTheBlockingPathContents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = UsageStateStore(stateURL: fixture.stateURL, acquireLease: false)
        #expect(try store.load() == nil)

        try FileManager.default.createDirectory(at: fixture.stateURL, withIntermediateDirectories: false)
        let sentinelURL = fixture.stateURL.appendingPathComponent("sentinel")
        let sentinel = Data("preserve this entry".utf8)
        try sentinel.write(to: sentinelURL)

        #expect(throws: (any Error).self) { try store.save(state()) }
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path))
        store.close()
    }

    @Test
    func envelopeAboveReadLimitIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x20, count: UsageStorageLimits.maximumEnvelopeBytes + 1).write(to: fixture.stateURL)

        #expect(throws: (any Error).self) { try UsageStateStore.readState(at: fixture.stateURL) }
    }

    @Test
    func invalidProjectionCannotBeWritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var value = state()
        var invalid = snapshot(at: Date(timeIntervalSince1970: 1_792_944_000))
        invalid.schemaVersion = 99
        value.widgetSnapshot = invalid
        let original = try UsageStateStore.encoded(state())
        try original.write(to: fixture.stateURL)

        #expect(throws: (any Error).self) { try UsageStateStore.saveState(value, at: fixture.stateURL) }
        #expect(try Data(contentsOf: fixture.stateURL) == original)
    }
}
