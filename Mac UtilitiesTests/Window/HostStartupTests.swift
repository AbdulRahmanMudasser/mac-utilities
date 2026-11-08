import AppKit
import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct HostStartupTests {
    @Test func failedBootstrapNeverConstructsFeatures() async {
        var constructed = 0
        let startup = HostStartupController(bootstrap: { throw HostMigrationError.invalidBackup },
            makeRuntime: { delegate, store in
                constructed += 1
                return HostRuntime(appDelegate: delegate, productionStore: store)
            })
        let delegate = AppDelegate()
        startup.start(appDelegate: delegate)
        await startup.waitUntilFinished()
        #expect(constructed == 0)
        #expect(startup.runtime == nil)
        guard case .failed = startup.state else { Issue.record("Expected a recovery state"); return }
    }

    @Test func bootstrapCompletesBeforeFeatureConstructionAndRunsOnce() async {
        var constructed = 0
        let startup = HostStartupController(bootstrap: { nil }, makeRuntime: { delegate, store in
            constructed += 1
            return HostRuntime(appDelegate: delegate, productionStore: store)
        })
        #expect(constructed == 0)
        let delegate = AppDelegate()
        startup.start(appDelegate: delegate)
        startup.start(appDelegate: delegate)
        await startup.waitUntilFinished()
        #expect(startup.state == .ready)
        #expect(constructed == 1)
        startup.runtime?.monitor.shutdown()
        startup.runtime?.keepAwakeController.shutdown()
        startup.runtime?.notificationsController.shutdown()
        await startup.runtime?.transcribeController.shutdown()
    }

    @Test func cancellationPreventsFeatureConstruction() async {
        var constructed = 0
        let startup = HostStartupController(bootstrap: { nil }, makeRuntime: { delegate, store in
            constructed += 1
            return HostRuntime(appDelegate: delegate, productionStore: store)
        })
        let delegate = AppDelegate()
        startup.start(appDelegate: delegate)
        startup.cancel()
        await startup.waitUntilFinished()
        #expect(constructed == 0)
        #expect(startup.state == .cancelled)
        #expect(startup.runtime == nil)
    }
    @Test func terminationWaitsForStartupCleanup() async {
        let delegate = AppDelegate()
        var cancelled = false
        var replies = 0
        var cleanup: CheckedContinuation<Void, Never>?
        delegate.cancelStartup = { cancelled = true }
        delegate.waitForStartup = { await withCheckedContinuation { cleanup = $0 } }
        delegate.replyToTermination = { if $0 { replies += 1 } }
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        for _ in 0..<100 where cleanup == nil { await Task.yield() }
        #expect(cancelled)
        #expect(replies == 0)
        #expect(cleanup != nil)
        cleanup?.resume()
        for _ in 0..<100 where replies == 0 { await Task.yield() }
        #expect(replies == 1)
    }

}
