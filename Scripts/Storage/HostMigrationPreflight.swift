import AppKit
import Foundation

@main
struct HostMigrationPreflight {
    static func main() {
        do {
            var values: [String: String] = [:]
            var arguments = Array(CommandLine.arguments.dropFirst())
            while !arguments.isEmpty {
                let key = arguments.removeFirst()
                guard key.hasPrefix("--"), !arguments.isEmpty, values[key] == nil else { throw HostMigrationError.unsafeInput }
                values[key] = arguments.removeFirst()
            }
            let allowed = Set(["--source-transcribe", "--source-preferences", "--usage-state", "--backup-directory",
                               "--bundle-identifier", "--destination-transcribe", "--receipt", "--restore-directory"])
            guard Set(values.keys).isSubset(of: allowed) else { throw HostMigrationError.unsafeInput }
            func path(_ key: String) throws -> URL {
                guard let raw = values[key], raw.hasPrefix("/") else { throw HostMigrationError.unsafeInput }
                return URL(fileURLWithPath: raw)
            }
            guard let bundleID = values["--bundle-identifier"], bundleID == "com.abdulrahman.mac-utilities" else {
                throw HostMigrationError.unsafeInput
            }
            let support = try TranscriptionStoragePaths.resolve()
            let locations = HostMigrationLocations(sourceTranscribe: try path("--source-transcribe"),
                sourcePreferences: try path("--source-preferences"), usageState: try path("--usage-state"),
                destinationRoot: values["--destination-transcribe"] != nil ? try path("--destination-transcribe") : support.transcribe,
                receiptURL: values["--receipt"] != nil ? try path("--receipt") : support.receipt,
                bundleIdentifier: bundleID)
            let migration = HostStorageMigration(locations: locations, writerIsRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.isEmpty
            })
            if values["--restore-directory"] != nil {
                try migration.restoreBackup(to: path("--restore-directory"))
                print("restore_verified")
            } else {
                _ = try migration.prepare(backupDirectory: path("--backup-directory"), forbiddenRoots: [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)])
                print("backup_verified")
            }
        } catch {
            let code = (error as? HostMigrationError)?.rawValue ?? HostMigrationError.invalidSource.rawValue
            fputs("migration_failed_\(code)\n", stderr)
            exit(code)
        }
    }
}
