import Foundation

nonisolated struct HostMigrationLocations: Codable, Equatable, Sendable {
    let sourceTranscribe: URL
    let sourcePreferences: URL
    let usageState: URL
    let destinationRoot: URL
    let receiptURL: URL
    let bundleIdentifier: String
}

nonisolated struct HostMigrationReceipt: Codable, Sendable {
    enum State: String, Codable { case backupVerified, staging, destinationVerified, committed }
    struct Entry: Codable, Equatable, Sendable {
        let store: String
        let relativePath: String
        let fingerprint: HostMigrationFiles.Fingerprint
        let schemaVersion: Int
    }
    let migrationID: UUID
    let schemaVersion: Int
    let bundleIdentifier: String
    let createdAt: Date
    let locations: HostMigrationLocations
    let sourcePresence: [String: Bool]
    let sourceFingerprints: [String: HostMigrationFiles.Fingerprint]
    let backupRoot: URL
    let destinationRoot: URL
    let entries: [Entry]
    var state: State
    var preferenceBefore: Data?
    var preferenceAfter: Data?
}

nonisolated final class HostStorageMigration {
    typealias Validation = (URL, String) throws -> Void
    let locations: HostMigrationLocations
    private let validate: Validation
    private let writerIsRunning: () -> Bool
    private let freeBytes: (URL) throws -> Int64
    private let checkpoint: (String) throws -> Void

    init(locations: HostMigrationLocations, writerIsRunning: @escaping () -> Bool,
         validate: @escaping Validation = HostMigrationValidation.validate,
         freeBytes: @escaping (URL) throws -> Int64 = { url in
             var existing = url
             while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                 existing.deleteLastPathComponent()
             }
             let attributes = try FileManager.default.attributesOfFileSystem(forPath: existing.path)
             return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
         }, checkpoint: @escaping (String) throws -> Void = { _ in }) {
        self.locations = locations
        self.writerIsRunning = writerIsRunning
        self.validate = validate
        self.freeBytes = freeBytes
        self.checkpoint = checkpoint
    }

    func prepare(backupDirectory: URL, forbiddenRoots: [URL]) throws -> HostMigrationReceipt {
        try validateLocations()
        try validateBackupRoot(backupDirectory, forbiddenRoots: forbiddenRoots)
        let lease = try exclusiveLease()
        defer { lease.close() }
        try ensureStopped()
        if try HostMigrationFiles.exists(locations.receiptURL) {
            let prior = try readReceipt()
            guard prior.state != .committed else { throw HostMigrationError.conflict }
        }
        let source = try inventory()
        let total = source.entries.reduce(Int64(0)) { $0 + $1.fingerprint.bytes }
        guard try freeBytes(backupDirectory) > total * 2 + 16_777_216,
              try freeBytes(locations.destinationRoot) > total * 2 + 16_777_216 else { throw HostMigrationError.insufficientSpace }
        let id = UUID()
        let backup = backupDirectory.appendingPathComponent("host-storage-v1-\(id.uuidString)", isDirectory: true)
        try HostMigrationFiles.privateDirectory(backup)
        for entry in source.entries {
            try ensureStopped()
            try checkpoint("backupCopy")
            let output = backup.appendingPathComponent(entry.relativePath)
            if entry.store == "preferences" {
                try HostMigrationFiles.write(source.preferences, to: output)
            } else {
                try HostMigrationFiles.copy(sourceURL(for: entry), to: output, expected: entry.fingerprint)
            }
        }
        let afterCopy = try inventory()
        guard afterCopy.fingerprints == source.fingerprints, afterCopy.presence == source.presence,
              afterCopy.entries == source.entries else { throw HostMigrationError.changedSource }
        let receipt = HostMigrationReceipt(migrationID: id, schemaVersion: 1,
            bundleIdentifier: locations.bundleIdentifier, createdAt: Date(), locations: locations,
            sourcePresence: source.presence, sourceFingerprints: source.fingerprints,
            backupRoot: backup, destinationRoot: locations.destinationRoot, entries: source.entries,
            state: .backupVerified)
        try verifyBackup(receipt, validateModels: false)
        try ensureStopped()
        try persist(receipt, to: backup.appendingPathComponent("receipt.json"))
        try persist(receipt)
        return receipt
    }

    func migrate(preferences: UserDefaults, domain: String, holding suppliedLease: UsageWriterLease? = nil) throws {
        try validateLocations()
        let lease = try suppliedLease ?? exclusiveLease()
        defer { if suppliedLease == nil { lease.close() } }
        try ensureStopped()
        guard try HostMigrationFiles.exists(locations.receiptURL) else {
            let source = try inventory()
            guard source.entries.isEmpty else { throw HostMigrationError.invalidBackup }
            let receipt = HostMigrationReceipt(migrationID: UUID(), schemaVersion: 1,
                bundleIdentifier: locations.bundleIdentifier, createdAt: Date(), locations: locations,
                sourcePresence: source.presence, sourceFingerprints: source.fingerprints,
                backupRoot: locations.receiptURL.deletingLastPathComponent().appendingPathComponent("unused"),
                destinationRoot: locations.destinationRoot, entries: [], state: .committed)
            try persist(receipt)
            return
        }
        var receipt = try readReceipt()
        // A committed receipt is terminal. Never reimport retained legacy data after a deletion.
        if receipt.state == .committed { return }
        try verifyBackup(receipt)
        let source = try inventory()
        guard source.fingerprints == receipt.sourceFingerprints,
              source.presence == receipt.sourcePresence, source.entries == receipt.entries else { throw HostMigrationError.changedSource }
        try ensureStopped()
        if receipt.state == .backupVerified {
            let current = preferences.persistentDomain(forName: domain) ?? [:]
            let incoming = try HostMigrationPreferences.validated(source.preferences)
            var before: [String: Any] = [:]
            var after: [String: Any] = [:]
            for (key, value) in incoming {
                if let existing = current[key] { before[key] = existing; after[key] = existing }
                else { after[key] = value }
            }
            receipt.preferenceBefore = try HostMigrationPreferences.encode(before)
            receipt.preferenceAfter = try HostMigrationPreferences.encode(after)
            receipt.state = .staging
            try persist(receipt)
        }
        let stage = locations.receiptURL.deletingLastPathComponent().appendingPathComponent("staging-\(receipt.migrationID.uuidString)")
        for entry in receipt.entries where entry.store == "transcribe" {
            try ensureStopped()
            let staged = stage.appendingPathComponent(entry.relativePath)
            try HostMigrationFiles.copy(receipt.backupRoot.appendingPathComponent(entry.relativePath), to: staged, expected: entry.fingerprint)
            try validate(staged, String(entry.relativePath.dropFirst("Transcribe/".count)))
        }
        for entry in receipt.entries where entry.store == "transcribe" {
            let destination = destinationURL(for: entry)
            if try HostMigrationFiles.exists(destination), try HostMigrationFiles.fingerprint(destination) != entry.fingerprint {
                throw HostMigrationError.conflict
            }
        }
        for entry in receipt.entries where entry.store == "transcribe" {
            try ensureStopped()
            try HostMigrationFiles.copy(stage.appendingPathComponent(entry.relativePath),
                                        to: destinationURL(for: entry), expected: entry.fingerprint)
            try checkpoint("filePublished")
        }
        receipt.state = .destinationVerified
        try persist(receipt)
        try checkpoint("beforePreferences")
        guard let beforeData = receipt.preferenceBefore, let afterData = receipt.preferenceAfter else { throw HostMigrationError.invalidBackup }
        let before = try plist(beforeData)
        let after = try plist(afterData)
        for key in after.keys.sorted() {
            try ensureStopped()
            let current = preferences.persistentDomain(forName: domain)?[key]
            guard equal(current, before[key]) || equal(current, after[key]) else { throw HostMigrationError.conflict }
            preferences.set(after[key], forKey: key)
            guard preferences.synchronize(), equal(preferences.persistentDomain(forName: domain)?[key], after[key]) else {
                throw HostMigrationError.conflict
            }
            try checkpoint("preferencePublished")
        }
        try checkpoint("beforeCommit")
        try ensureStopped()
        receipt.state = .committed
        try persist(receipt)
        try? FileManager.default.removeItem(at: stage)
    }

    func readReceipt() throws -> HostMigrationReceipt {
        let receipt: HostMigrationReceipt
        do { receipt = try JSONDecoder().decode(HostMigrationReceipt.self, from: HostMigrationFiles.data(locations.receiptURL)) }
        catch { throw HostMigrationError.invalidBackup }
        guard receipt.schemaVersion == 1, receipt.bundleIdentifier == locations.bundleIdentifier,
              receipt.locations == locations, receipt.destinationRoot == locations.destinationRoot,
              receipt.createdAt.timeIntervalSince1970.isFinite,
              Set(receipt.entries.map(\.relativePath)).count == receipt.entries.count else { throw HostMigrationError.invalidBackup }
        for entry in receipt.entries {
            let components = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.relativePath.hasPrefix("/"), !components.contains(".."), !components.contains("."),
                  !components.contains(""), ["transcribe", "preferences", "usage"].contains(entry.store),
                  (entry.store == "usage" ? (1...3).contains(entry.schemaVersion) : entry.schemaVersion == 1),
                  entry.fingerprint.bytes >= 0,
                  entry.fingerprint.sha256.count == 64,
                  entry.fingerprint.sha256.allSatisfy({ $0.isHexDigit }) else { throw HostMigrationError.invalidBackup }
            let permitted = entry.store == "transcribe" ? (entry.relativePath == "Transcribe/history.json" || HostMigrationValidation.isModelPath(String(entry.relativePath.dropFirst("Transcribe/".count))) && entry.relativePath.hasPrefix("Transcribe/")) :
                entry.relativePath == (entry.store == "usage" ? "Usage/today-usage.json" : "Preferences/allowlist.plist")
            guard permitted else { throw HostMigrationError.invalidBackup }
        }
        if receipt.state != .committed {
            try validateBackupRoot(receipt.backupRoot, forbiddenRoots: [])
        }
        return receipt
    }

    func verifyBackup(_ receipt: HostMigrationReceipt, validateModels: Bool = true) throws {
        try validateBackupRoot(receipt.backupRoot, forbiddenRoots: [])
        for entry in receipt.entries {
            let url = receipt.backupRoot.appendingPathComponent(entry.relativePath)
            guard try HostMigrationFiles.fingerprint(url) == entry.fingerprint else { throw HostMigrationError.invalidBackup }
            switch entry.store {
            case "transcribe":
                let path = String(entry.relativePath.dropFirst("Transcribe/".count))
                if validateModels || !HostMigrationValidation.isModelPath(path) { try validate(url, path) }
            case "usage": _ = try UsageStateStore.readState(at: url)
            case "preferences": _ = try HostMigrationPreferences.validated(HostMigrationFiles.data(url))
            default: throw HostMigrationError.invalidBackup
            }
        }
    }

    // Restore only into an empty recovery directory. Never restore over current stores or deletions.
    func restoreBackup(to recoveryRoot: URL) throws {
        let lease = try exclusiveLease()
        defer { lease.close() }
        try ensureStopped()
        let receipt = try readReceipt()
        try validateBackupRoot(recoveryRoot, forbiddenRoots: [receipt.backupRoot])
        guard !(try HostMigrationFiles.exists(recoveryRoot)) else { throw HostMigrationError.conflict }
        try verifyBackup(receipt, validateModels: false)
        try HostMigrationFiles.privateDirectory(recoveryRoot)
        for entry in receipt.entries {
            try ensureStopped()
            try HostMigrationFiles.copy(receipt.backupRoot.appendingPathComponent(entry.relativePath),
                                        to: recoveryRoot.appendingPathComponent(entry.relativePath), expected: entry.fingerprint)
        }
        try persist(receipt, to: recoveryRoot.appendingPathComponent("receipt.json"))
    }

    private struct Inventory {
        var entries: [HostMigrationReceipt.Entry] = []
        var fingerprints: [String: HostMigrationFiles.Fingerprint] = [:]
        var presence: [String: Bool] = [:]
        var preferences = Data()
    }

    private func inventory() throws -> Inventory {
        var result = Inventory()
        for (name, url) in [("transcribe", locations.sourceTranscribe), ("preferences", locations.sourcePreferences), ("usage", locations.usageState)] {
            try HostMigrationFiles.checkPath(url)
            result.presence[name] = try HostMigrationFiles.exists(url)
        }
        if result.presence["transcribe"] == true {
            let root = locations.sourceTranscribe
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw HostMigrationError.unsafeInput }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw HostMigrationError.invalidSource }
            for case let file as URL in enumerator {
                try HostMigrationFiles.checkPath(file)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw HostMigrationError.unsafeInput }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { throw HostMigrationError.unsafeInput }
                let path = String(file.path.dropFirst(root.path.count + 1))
                let lockNames = [SpeechModelMetadata.pinnedEnglish, .pinnedUrdu, .pinnedVAD].map { "Models/." + $0.fileName + ".lock" }
                if lockNames.contains(path) { continue }
                if !HostMigrationValidation.isModelPath(path) { try validate(file, path) }
                let signature = try HostMigrationFiles.fingerprint(file)
                result.fingerprints["Transcribe/" + path] = signature
                result.entries.append(.init(store: "transcribe", relativePath: "Transcribe/" + path, fingerprint: signature, schemaVersion: 1))
            }
            guard !enumerationFailed else { throw HostMigrationError.invalidSource }
        }
        let preferences: [String: Any]
        if result.presence["preferences"] == true {
            let data = try HostMigrationFiles.data(locations.sourcePreferences)
            preferences = try HostMigrationPreferences.validated(data)
            result.fingerprints["sourcePreferences"] = try HostMigrationFiles.fingerprint(locations.sourcePreferences)
        } else { preferences = [:] }
        result.preferences = try HostMigrationPreferences.encode(preferences)
        if !preferences.isEmpty {
            let digest = HostMigrationValidation.fingerprint(result.preferences)
            result.entries.append(.init(store: "preferences", relativePath: "Preferences/allowlist.plist", fingerprint: digest, schemaVersion: 1))
        }
        if result.presence["usage"] == true {
            guard let usage = try UsageStateStore.readState(at: locations.usageState) else { throw HostMigrationError.invalidSource }
            let signature = try HostMigrationFiles.fingerprint(locations.usageState)
            result.fingerprints["Usage/today-usage.json"] = signature
            result.entries.append(.init(store: "usage", relativePath: "Usage/today-usage.json", fingerprint: signature, schemaVersion: usage.schemaVersion))
        }
        result.entries.sort { $0.relativePath < $1.relativePath }
        return result
    }

    private func validateLocations() throws {
        guard !locations.bundleIdentifier.isEmpty, !locations.bundleIdentifier.contains("/") else { throw HostMigrationError.unsafeInput }
        let roots = [locations.sourceTranscribe, locations.sourcePreferences, locations.usageState, locations.destinationRoot, locations.receiptURL]
        for root in roots { try HostMigrationFiles.checkPath(root) }
        for i in roots.indices {
            for j in roots.indices where j > i {
                guard !HostMigrationFiles.overlaps(roots[i], roots[j]) else { throw HostMigrationError.unsafeInput }
            }
        }
    }

    private func validateBackupRoot(_ root: URL, forbiddenRoots: [URL]) throws {
        try HostMigrationFiles.checkPath(root)
        let prohibited = [locations.sourceTranscribe, locations.sourcePreferences, locations.usageState,
                          locations.destinationRoot, locations.receiptURL.deletingLastPathComponent(),
                          URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: "/private/var/folders"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")] + forbiddenRoots
        guard !prohibited.contains(where: { HostMigrationFiles.overlaps(root, $0) }) else { throw HostMigrationError.unsafeInput }
        var parent = root
        while parent.path != "/" {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) { throw HostMigrationError.unsafeInput }
            parent.deleteLastPathComponent()
        }
    }

    private func exclusiveLease() throws -> UsageWriterLease {
        do { return try UsageWriterLease(url: UsageStateStore.leaseURL(for: locations.usageState)) }
        catch { throw HostMigrationError.activeWriter }
    }

    private func ensureStopped() throws {
        try Task.checkCancellation()
        guard !writerIsRunning() else { throw HostMigrationError.activeWriter }
    }

    private func sourceURL(for entry: HostMigrationReceipt.Entry) -> URL {
        entry.store == "usage" ? locations.usageState : locations.sourceTranscribe.appendingPathComponent(String(entry.relativePath.dropFirst("Transcribe/".count)))
    }

    private func destinationURL(for entry: HostMigrationReceipt.Entry) -> URL {
        locations.destinationRoot.appendingPathComponent(String(entry.relativePath.dropFirst("Transcribe/".count)))
    }

    private func persist(_ receipt: HostMigrationReceipt, to url: URL? = nil) throws {
        try HostMigrationFiles.write(JSONEncoder().encode(receipt), to: url ?? locations.receiptURL)
    }

    private func plist(_ data: Data) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(values.keys).isSubset(of: Set(HostMigrationPreferences.keys)) else { throw HostMigrationError.invalidBackup }
        return values
    }

    private func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return (a as? NSObject)?.isEqual(b) == true
    }
}
