import AppKit
import Combine

nonisolated struct HostStartupStorage: @unchecked Sendable {
    let stateURL: URL
    let lease: UsageWriterLease
}

@MainActor
final class HostStartupController: ObservableObject {
    enum State: Equatable { case idle, migrating, ready, failed(String), cancelled }
    @Published private(set) var state: State = .idle
    @Published private(set) var runtime: HostRuntime?
    private var task: Task<Void, Never>?
    private weak var appDelegate: AppDelegate?
    private var generation = 0
    private var worker: Task<Result<HostStartupStorage?, Error>, Never>?
    private let bootstrap: @Sendable () throws -> HostStartupStorage?
    private let makeRuntime: @MainActor (AppDelegate, UsageStateStore?) -> HostRuntime

    init(bootstrap: @escaping @Sendable () throws -> HostStartupStorage? = HostStartupController.bootstrap,
         makeRuntime: @escaping @MainActor (AppDelegate, UsageStateStore?) -> HostRuntime = { HostRuntime(appDelegate: $0, productionStore: $1) }) {
        self.bootstrap = bootstrap
        self.makeRuntime = makeRuntime
    }

    func start(appDelegate: AppDelegate) {
        guard task == nil, runtime == nil else { return }
        self.appDelegate = appDelegate
        generation += 1
        let token = generation
        state = .migrating
        appDelegate.cancelStartup = { [weak self] in self?.cancel() }
        appDelegate.waitForStartup = { [weak self] in await self?.waitUntilFinished() }
        let bootstrap = bootstrap
        let worker = Task.detached { () -> Result<HostStartupStorage?, Error> in
            Result { try bootstrap() }
        }
        self.worker = worker
        task = Task { [weak self, weak appDelegate] in
            let result = await worker.value
            self?.task = nil
            self?.worker = nil
            guard let self, self.generation == token, let appDelegate else {
                if case .success(let storage) = result { storage?.lease.close() }
                return
            }
            switch result {
            case .success(let storage):
                let store = storage.map { UsageStateStore(stateURL: $0.stateURL, existingLease: $0.lease) }
                self.runtime = self.makeRuntime(appDelegate, store)
                self.state = .ready
                appDelegate.completeStartup()
            case .failure(let error):
                self.state = .failed((error as? HostMigrationError)?.localizedDescription ?? "Saved data could not be migrated. The original files have been kept.")
            }
        }
    }

    func retry() {
        guard let appDelegate else { return }
        start(appDelegate: appDelegate)
    }

    func waitUntilFinished() async { await task?.value }

    func cancel() {
        guard runtime == nil else { return }
        generation += 1
        task?.cancel()
        worker?.cancel()
        state = .cancelled
    }

    nonisolated private static func bootstrap() throws -> HostStartupStorage? {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        if testing { return nil }
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.contains("-preview") || $0.hasPrefix("--transcribe-native-check=") }),
           CommandLine.arguments.contains(where: { $0.hasPrefix("--usage-preview") || $0.hasPrefix("--settings-preview") || $0.hasPrefix("--stability-preview") || $0.hasPrefix("--keep-awake-preview") || $0.hasPrefix("--notification-preview") || $0.hasPrefix("--transcribe-preview") || $0.hasPrefix("--transcribe-native-check=") }) { return nil }
        if try UsageStoragePaths.resolve().isVerification { return nil }
        #endif
        let usage = try UsageStoragePaths.resolve()
        let paths = try TranscriptionStoragePaths.resolve()
        guard let bundleID = Bundle.main.bundleIdentifier else { throw HostMigrationError.unsafeInput }
        let receipt: HostMigrationLocations
        if try HostMigrationFiles.exists(paths.receipt) {
            let data = try HostMigrationFiles.data(paths.receipt)
            guard let saved = try? JSONDecoder().decode(HostMigrationReceipt.self, from: data),
                  saved.locations.destinationRoot == paths.transcribe,
                  saved.locations.receiptURL == paths.receipt,
                  saved.locations.usageState == usage.stateURL,
                  saved.bundleIdentifier == bundleID else { throw HostMigrationError.invalidBackup }
            receipt = saved.locations
        } else {
            // macOS exposes no public legacy-container lookup for an unsandboxed host.
            // The identity-derived location is inspected only; a populated source requires explicit preflight.
            let legacy = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library")
            receipt = HostMigrationLocations(
                sourceTranscribe: legacy.appendingPathComponent("Application Support/MacUtilities/Transcribe"),
                sourcePreferences: legacy.appendingPathComponent("Preferences/\(bundleID).plist"),
                usageState: usage.stateURL, destinationRoot: paths.transcribe, receiptURL: paths.receipt,
                bundleIdentifier: bundleID)
        }
        let lease = try UsageWriterLease(url: UsageStateStore.leaseURL(for: usage.stateURL))
        do {
            let migration = HostStorageMigration(locations: receipt, writerIsRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            })
            try migration.migrate(preferences: .standard, domain: bundleID, holding: lease)
            return HostStartupStorage(stateURL: usage.stateURL, lease: lease)
        } catch {
            lease.close()
            throw error
        }
    }
}
