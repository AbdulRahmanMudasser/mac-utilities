import Darwin
import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct TranscriptionHistoryStoreTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        var historyURL: URL { directory.appendingPathComponent("transcription-history.json") }
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcription-history-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func makeStore() -> TranscriptionHistoryStore {
            TranscriptionHistoryStore(historyURL: historyURL, now: { self.now })
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test
    func missingFileLoadsEmptyAndMutationRequiresSuccessfulLoad() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()

        #expect(try store.load().isEmpty)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))

        let unloadedStore = fixture.makeStore()
        #expect(throws: (any Error).self) { try unloadedStore.append("not written") }
        #expect(throws: (any Error).self) { try unloadedStore.delete(id: UUID()) }
        #expect(throws: (any Error).self) { try unloadedStore.clear() }
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))
    }

    @Test
    func emptyTranscriptCannotBeAppendedToHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)

        #expect(throws: TranscriptionHistoryStore.StorageError.emptyTranscript) {
            try store.append(" \n\t ")
        }
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))
    }

    @Test
    func existingEmptyTranscriptIsRejectedAndPreserved() throws {
        struct Document: Encodable {
            let schemaVersion: Int
            let entries: [TranscriptionHistoryEntry]
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = try JSONEncoder().encode(Document(
            schemaVersion: 1,
            entries: [TranscriptionHistoryEntry(text: " \n ", savedAt: fixture.now)]
        ))
        try data.write(to: fixture.historyURL)

        let store = fixture.makeStore()
        #expect(throws: TranscriptionHistoryStore.StorageError.invalidHistory) {
            try store.load()
        }
        #expect(try Data(contentsOf: fixture.historyURL) == data)
        #expect(store.entries.isEmpty)
    }

    @Test
    func historyStorageUsesOwnerOnlyPermissionsAndRepairsExistingModes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()

        #expect(try store.load().isEmpty)
        let saved = try store.append("private transcript")
        #expect(try permissions(of: fixture.directory) == 0o700)
        #expect(try permissions(of: fixture.historyURL) == 0o600)

        #expect(chmod(fixture.directory.path, 0o755) == 0)
        #expect(chmod(fixture.historyURL.path, 0o644) == 0)
        #expect(try fixture.makeStore().load() == [saved])
        #expect(try permissions(of: fixture.directory) == 0o700)
        #expect(try permissions(of: fixture.historyURL) == 0o600)
    }

    @Test
    func symbolicLinkHistoryIsRejectedWithoutReadingItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let targetURL = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("history-target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: targetURL) }
        let target = Data("must remain untouched".utf8)
        try target.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.historyURL, withDestinationURL: targetURL)

        #expect(throws: (any Error).self) { try fixture.makeStore().load() }
        #expect(try Data(contentsOf: targetURL) == target)
    }

    @Test
    func entriesGetStableIdentityAndSaveTimeAndRemainAfterTimeAdvances() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)

        let savedAt = fixture.now
        let first = try store.append("same transcript")
        let second = try store.append("same transcript")
        #expect(first.id != second.id)
        #expect(first.text == second.text)
        #expect(first.savedAt == savedAt)
        #expect(second.savedAt == savedAt)

        fixture.now = savedAt.addingTimeInterval(100 * 365 * 24 * 60 * 60)
        let relaunchedStore = fixture.makeStore()
        #expect(try relaunchedStore.load() == [first, second])
        #expect(relaunchedStore.entries.map(\.id) == [first.id, second.id])
    }

    @Test
    func deleteTargetsOneOfTwoEntriesWithMatchingTextAndTimestamp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)

        let first = try store.append("duplicate")
        let second = try store.append("duplicate")
        try store.delete(id: first.id)

        #expect(store.entries == [second])
        let relaunchedStore = fixture.makeStore()
        #expect(try relaunchedStore.load() == [second])

        try relaunchedStore.delete(id: first.id)
        #expect(relaunchedStore.entries == [second])
    }

    @Test
    func clearRemovesEveryEntryAndPersistsTheEmptyHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)
        _ = try store.append("first transcript")
        _ = try store.append("second transcript")

        try store.clear()

        #expect(store.entries.isEmpty)
        #expect(try fixture.makeStore().load().isEmpty)
        try store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test
    func failedLoadPreservesInMemoryEntriesAndCorruptFileAndBlocksWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)
        let saved = try store.append("retained in memory")

        let corruptData = Data("{".utf8)
        try corruptData.write(to: fixture.historyURL)
        #expect(throws: (any Error).self) { try store.load() }

        #expect(store.entries == [saved])
        #expect(try Data(contentsOf: fixture.historyURL) == corruptData)
        #expect(throws: (any Error).self) { try store.append("must not replace corruption") }
        #expect(store.entries == [saved])
        #expect(try Data(contentsOf: fixture.historyURL) == corruptData)
    }

    @Test
    func failedAppendDeleteAndClearKeepInMemoryStateAndBlockingPathContents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)

        try FileManager.default.createDirectory(at: fixture.historyURL, withIntermediateDirectories: false)
        let appendSentinelURL = fixture.historyURL.appendingPathComponent("sentinel")
        let appendSentinel = Data("preserve append blocker".utf8)
        try appendSentinel.write(to: appendSentinelURL)
        #expect(throws: (any Error).self) { try store.append("not committed") }
        #expect(store.entries.isEmpty)
        #expect(try Data(contentsOf: appendSentinelURL) == appendSentinel)

        try FileManager.default.removeItem(at: appendSentinelURL)
        try FileManager.default.removeItem(at: fixture.historyURL)
        let saved = try store.append("committed before delete failure")
        #expect(try fixture.makeStore().load() == [saved])
        try FileManager.default.removeItem(at: fixture.historyURL)
        try FileManager.default.createDirectory(at: fixture.historyURL, withIntermediateDirectories: false)
        let deleteSentinelURL = fixture.historyURL.appendingPathComponent("sentinel")
        let deleteSentinel = Data("preserve delete blocker".utf8)
        try deleteSentinel.write(to: deleteSentinelURL)

        #expect(throws: (any Error).self) { try store.delete(id: saved.id) }
        #expect(store.entries == [saved])
        #expect(try Data(contentsOf: deleteSentinelURL) == deleteSentinel)
        #expect(throws: (any Error).self) { try store.clear() }
        #expect(store.entries == [saved])
        #expect(try Data(contentsOf: deleteSentinelURL) == deleteSentinel)
    }

    @Test
    func unsupportedSchemaIsReportedWithoutChangingFileOrInMemoryEntries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try store.load().isEmpty)
        let saved = try store.append("keep this state")

        let unsupported = Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        try unsupported.write(to: fixture.historyURL)
        #expect(throws: (any Error).self) { try store.load() }

        #expect(store.entries == [saved])
        #expect(try Data(contentsOf: fixture.historyURL) == unsupported)
    }

    private func permissions(of url: URL) throws -> mode_t {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_mode & 0o777
    }
}
