import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct HostStorageMigrationTests {
    @MainActor final class Fixture {
        let root: URL
        let domain = "MacUtilities.MigrationTests.\(UUID().uuidString)"
        let preferences: UserDefaults
        let locations: HostMigrationLocations
        var backups: URL { root.appendingPathComponent("Backups") }
        var failAt: String?
        var active = false
        var space: Int64 = .max

        init() throws {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacUtilitiesMigrationTests-\(UUID().uuidString)")
            preferences = UserDefaults(suiteName: domain)!
            locations = HostMigrationLocations(sourceTranscribe: root.appendingPathComponent("Legacy/Transcribe"),
                sourcePreferences: root.appendingPathComponent("Legacy/preferences.plist"),
                usageState: root.appendingPathComponent("Group/today-usage.json"),
                destinationRoot: root.appendingPathComponent("Destination/Transcribe"),
                receiptURL: root.appendingPathComponent("Destination/Migration/host-storage-v1.json"),
                bundleIdentifier: "com.abdulrahman.mac-utilities")
            try HostMigrationFiles.privateDirectory(root)
        }
        func migration() -> HostStorageMigration {
            HostStorageMigration(locations: locations, writerIsRunning: { self.active },
                freeBytes: { _ in self.space }, checkpoint: { point in
                    if self.failAt == point { throw HostMigrationError.cancelled }
                })
        }
        func seed() throws {
            let history = TranscriptionHistoryStore(historyURL: locations.sourceTranscribe.appendingPathComponent("history.json"),
                now: { Date(timeIntervalSince1970: 1_800_000_000) })
            try history.load()
            try history.append("Synthetic migration fixture.")
            try HostMigrationFiles.write(HostMigrationPreferences.encode([
                "speech.transcriptionLanguage.v1": "ur", "dataDisplayUnit": "binary",
                "notifications.keepAwakeTimer.v1": true, "ignoredPrivateValue": "excluded"
            ]), to: locations.sourcePreferences)
            try UsageStateStore.saveState(PersistedUsage(schemaVersion: 3, localDayKey: "2026-11-08", history: []), at: locations.usageState)
        }
        func run() throws { try migration().migrate(preferences: preferences, domain: domain) }
        func remove() {
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func populatedUpgradePreservesBytesAndPreferences() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let history = try HostMigrationFiles.fingerprint(f.locations.sourceTranscribe.appendingPathComponent("history.json"))
        let usage = try HostMigrationFiles.fingerprint(f.locations.usageState)
        f.preferences.set("decimal", forKey: "dataDisplayUnit")
        let receipt = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        #expect(receipt.state == .backupVerified)
        try f.run()
        #expect(try HostMigrationFiles.fingerprint(f.locations.destinationRoot.appendingPathComponent("history.json")) == history)
        #expect(try HostMigrationFiles.fingerprint(f.locations.usageState) == usage)
        #expect(f.preferences.string(forKey: "speech.transcriptionLanguage.v1") == "ur")
        #expect(f.preferences.string(forKey: "dataDisplayUnit") == "decimal")
        #expect(f.preferences.object(forKey: "ignoredPrivateValue") == nil)
        #expect(f.preferences.bool(forKey: "notifications.keepAwakeTimer.v1"))
        #expect(try f.migration().readReceipt().state == .committed)
    }

    @Test func noLegacyDataRecordsFreshInstall() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.run()
        #expect(try f.migration().readReceipt().state == .committed)
        try f.run()
    }

    @Test func populatedSourceRequiresBackup() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        #expect(throws: HostMigrationError.invalidBackup) { try f.run() }
        #expect(!(try HostMigrationFiles.exists(f.locations.destinationRoot)))
    }

    @Test func interruptedPublicationResumesWithoutDuplicateHistory() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        f.failAt = "filePublished"
        #expect(throws: HostMigrationError.cancelled) { try f.run() }
        #expect(f.preferences.string(forKey: "speech.transcriptionLanguage.v1") == nil)
        f.failAt = nil
        try f.run()
        let entries = try TranscriptionHistoryStore(historyURL: f.locations.destinationRoot.appendingPathComponent("history.json")).load()
        #expect(entries.count == 1)
        try f.run()
    }

    @Test(arguments: ["beforePreferences", "preferencePublished", "beforeCommit"])
    func interruptedPreferenceCommitResumes(point: String) throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        f.failAt = point
        #expect(throws: HostMigrationError.cancelled) { try f.run() }
        f.failAt = nil
        try f.run()
        #expect(try f.migration().readReceipt().state == .committed)
    }

    @Test func repeatedLaunchDoesNotResurrectDeletedHistory() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        try f.run()
        let store = TranscriptionHistoryStore(historyURL: f.locations.destinationRoot.appendingPathComponent("history.json"))
        try store.load(); try store.clear()
        try f.run()
        #expect(try store.load().isEmpty)
        try store.append("New synthetic entry.")
        try f.run()
        #expect(try store.load().count == 1)
    }

    @Test func changedSourceAndCorruptBackupBlockMigration() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let receipt = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        try HostMigrationFiles.write(Data("corrupt".utf8), to: receipt.backupRoot.appendingPathComponent("Transcribe/history.json"))
        #expect(throws: HostMigrationError.invalidBackup) { try f.run() }
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        let history = TranscriptionHistoryStore(historyURL: f.locations.sourceTranscribe.appendingPathComponent("history.json"))
        try history.load(); try history.append("Changed source.")
        #expect(throws: HostMigrationError.changedSource) { try f.run() }
    }

    @Test func conflictingDestinationAndPreferenceArePreserved() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        let store = TranscriptionHistoryStore(historyURL: f.locations.destinationRoot.appendingPathComponent("history.json"))
        try store.load(); try store.append("Other destination.")
        #expect(throws: HostMigrationError.conflict) { try f.run() }
        #expect(try store.load().first?.text == "Other destination.")
    }

    @Test func activeWriterLeaseAndInsufficientSpaceBlockBackup() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let lease = try UsageWriterLease(url: UsageStateStore.leaseURL(for: f.locations.usageState))
        #expect(throws: HostMigrationError.activeWriter) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        lease.close()
        f.active = true
        #expect(throws: HostMigrationError.activeWriter) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        f.active = false; f.space = 0
        #expect(throws: HostMigrationError.insufficientSpace) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
    }

    @Test func unsafeRootsSymlinksAndCorruptSourceAreRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        #expect(throws: HostMigrationError.unsafeInput) { try f.migration().prepare(backupDirectory: f.locations.sourceTranscribe, forbiddenRoots: []) }
        try FileManager.default.createSymbolicLink(at: f.locations.sourceTranscribe.appendingPathComponent("linked.json"),
            withDestinationURL: f.locations.sourceTranscribe.appendingPathComponent("history.json"))
        #expect(throws: HostMigrationError.unsafeInput) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        try FileManager.default.removeItem(at: f.locations.sourceTranscribe.appendingPathComponent("linked.json"))
        try HostMigrationFiles.write(Data("{}".utf8), to: f.locations.sourceTranscribe.appendingPathComponent("history.json"))
        #expect(throws: (any Error).self) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
    }

    @Test func restoreKeepsNewUsageAndHistoryDeletionUntouched() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        try f.run()
        let store = TranscriptionHistoryStore(historyURL: f.locations.destinationRoot.appendingPathComponent("history.json"))
        try store.load(); try store.clear()
        try UsageStateStore.saveState(PersistedUsage(schemaVersion: 3, localDayKey: "2026-11-08", downloaded: 999, history: []), at: f.locations.usageState)
        let usage = try HostMigrationFiles.fingerprint(f.locations.usageState)
        let recovery = f.root.appendingPathComponent("Recovery")
        try f.migration().restoreBackup(to: recovery)
        #expect(try HostMigrationFiles.fingerprint(f.locations.usageState) == usage)
        #expect(try store.load().isEmpty)
        #expect(try TranscriptionHistoryStore(historyURL: recovery.appendingPathComponent("Transcribe/history.json")).load().count == 1)
        #expect(throws: HostMigrationError.conflict) { try f.migration().restoreBackup(to: recovery) }
    }

    @Test func malformedReceiptCannotPublishPathsOutsideDestination() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        let original = try Data(contentsOf: f.locations.receiptURL)
        var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var entries = json["entries"] as! [[String: Any]]
        entries[0]["relativePath"] = "../escape"
        json["entries"] = entries
        try HostMigrationFiles.write(JSONSerialization.data(withJSONObject: json), to: f.locations.receiptURL)
        #expect(throws: HostMigrationError.invalidBackup) { try f.run() }
    }
    @Test func invalidModelIsBackedUpButBlocksStartup() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let path = "Models/" + SpeechModelMetadata.pinnedEnglish.fileName
        try HostMigrationFiles.write(Data("invalid model fixture".utf8), to: f.locations.sourceTranscribe.appendingPathComponent(path))
        let receipt = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        #expect(try HostMigrationFiles.exists(receipt.backupRoot.appendingPathComponent("Transcribe/" + path)))
        #expect(throws: HostMigrationError.invalidSource) { try f.run() }
        #expect(!(try HostMigrationFiles.exists(f.locations.destinationRoot)))
    }

    @Test func writerRestartDuringBackupIsRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let migration = HostStorageMigration(locations: f.locations, writerIsRunning: { f.active }, checkpoint: { point in
            if point == "backupCopy" { f.active = true }
        })
        #expect(throws: HostMigrationError.activeWriter) { try migration.prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        #expect(!(try HostMigrationFiles.exists(f.locations.receiptURL)))
    }

    @Test func preferenceConflictDuringInterruptedCommitIsNotOverwritten() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        f.failAt = "beforePreferences"
        #expect(throws: HostMigrationError.cancelled) { try f.run() }
        f.preferences.set("en", forKey: "speech.transcriptionLanguage.v1")
        f.failAt = nil
        #expect(throws: HostMigrationError.conflict) { try f.run() }
        #expect(f.preferences.string(forKey: "speech.transcriptionLanguage.v1") == "en")
    }

    @Test func migrationLeaseTransfersToOnlyUsageWriter() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        _ = try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: [])
        let lease = try UsageWriterLease(url: UsageStateStore.leaseURL(for: f.locations.usageState))
        try f.migration().migrate(preferences: f.preferences, domain: f.domain, holding: lease)
        let store = UsageStateStore(stateURL: f.locations.usageState, existingLease: lease)
        _ = try store.load()
        #expect(throws: UsageWriterLease.LeaseError.self) { try UsageWriterLease(url: UsageStateStore.leaseURL(for: f.locations.usageState)) }
        store.close()
        let next = try UsageWriterLease(url: UsageStateStore.leaseURL(for: f.locations.usageState))
        next.close()
    }

    @Test func sourceMutationDuringBackupInvalidatesReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let migration = HostStorageMigration(locations: f.locations, writerIsRunning: { false }, checkpoint: { point in
            if point == "backupCopy" {
                try HostMigrationFiles.write(HostMigrationPreferences.encode(["dataDisplayUnit": "decimal"]),
                    to: f.locations.sourcePreferences)
            }
        })
        #expect(throws: HostMigrationError.changedSource) { try migration.prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        #expect(!(try HostMigrationFiles.exists(f.locations.receiptURL)))
    }

    @Test func interruptedBackupLeavesSourceIntactAndNoReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.seed()
        let original = try HostMigrationFiles.fingerprint(f.locations.sourceTranscribe.appendingPathComponent("history.json"))
        f.failAt = "backupCopy"
        #expect(throws: HostMigrationError.cancelled) { try f.migration().prepare(backupDirectory: f.backups, forbiddenRoots: []) }
        #expect(try HostMigrationFiles.fingerprint(f.locations.sourceTranscribe.appendingPathComponent("history.json")) == original)
        #expect(!(try HostMigrationFiles.exists(f.locations.receiptURL)))
    }

}
