import AppKit
import Foundation
import Testing
@testable import Mac_Utilities

@Suite(.serialized)
@MainActor
struct StabilitySignedIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACUTILITIES_SIGNED_STABILITY_CHECK"] == "1"))
    func signedWorkspaceNotificationsInterruptAndReapBothChildren() async throws {
        let events = ConnectionObservationEvents()
        let childRunner = DiagnosticProcessRunner()
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, timeout in
            try await childRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: timeout)
        }, stabilityEvents: { events })
        diagnostics.startStability()
        for _ in 0..<100 where childRunner.activeProcessIDs.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(childRunner.activeProcessIDs.count == 2)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<100 where !childRunner.activeProcessIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(childRunner.activeProcessIDs.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        diagnostics.cancel()
        await diagnostics.waitUntilStopped()
        let result = try #require(diagnostics.stabilitySnapshot)
        #expect(result.status == .cancelled)
        #expect(result.gaps.contains { $0.reason == .sleep && $0.end > $0.start })
        #expect(result.observations.contains { if case .interrupted = $0.outcome { true } else { false } })
        #expect(result.observations.allSatisfy { $0.outcome != .noReply })
        #expect(!events.isObserving)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        #expect(diagnostics.stabilitySnapshot == result)
        print("SIGNED_NOTIFICATION_VERIFIED sleepWake=true childrenReaped=true staleEventsSuppressed=true")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACUTILITIES_SIGNED_STABILITY_CHECK"] == "1"))
    func signedFiveMinuteSessionAndRealProcessCleanup() async throws {
        let events = ConnectionObservationEvents()
        let diagnostics = ConnectionDiagnostics(stabilityEvents: { events })
        #expect(!events.isObserving)
        #expect(!diagnostics.isRunning)
        diagnostics.startStability()
        var maximumChildren = 0
        while diagnostics.isRunning {
            maximumChildren = max(maximumChildren, diagnostics.activeProcessIDs.count)
            try await Task.sleep(for: .seconds(1))
        }
        let result = try #require(diagnostics.stabilitySnapshot)
        #expect(result.status == .completed)
        #expect(result.elapsed == 300)
        #expect(result.observations.count == 120)
        #expect(maximumChildren <= 2)
        #expect(diagnostics.activeProcessIDs.isEmpty)
        #expect(!events.isObserving)
        #expect(result.observations.contains { $0.outcome.milliseconds != nil })
        for target in ProbeTarget.defaults {
            let summary = result.summary(for: target.id)
            #expect(summary.completed + summary.unobserved + summary.interrupted == 60)
            print("SIGNED_STABILITY target=\(target.id) completed=\(summary.completed) replies=\(summary.received) missed=\(summary.missed) unobserved=\(summary.unobserved) interrupted=\(summary.interrupted)")
        }

        // A reserved documentation address provides a controlled non-reply fixture;
        // it is never a production endpoint or a user-configurable destination.
        let runner = DiagnosticProcessRunner()
        let noReply = try await runner.run(executable: "/sbin/ping",
            arguments: ["-n", "-c", "1", "-i", "1", "-W", "1500", "-t", "2", "192.0.2.1"], timeout: 3)
        let missed = try ProbeStatistics.parse(String(decoding: noReply.stdout, as: UTF8.self),
            exitCode: noReply.exitCode, expectedCount: 1)
        #expect(missed.sent == 1 && missed.received == 0)
        #expect(runner.activeProcessIDs.isEmpty)

        diagnostics.startStability()
        for _ in 0..<100 where diagnostics.activeProcessIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        diagnostics.cancel()
        #expect(diagnostics.isRunning && diagnostics.isStopping)
        await diagnostics.waitUntilStopped()
        #expect(diagnostics.stabilitySnapshot?.status == .cancelled)
        #expect(diagnostics.activeProcessIDs.isEmpty)
        #expect(!events.isObserving)
        print("SIGNED_STABILITY_VERIFIED duration=300 slots=60 maxChildren=\(maximumChildren) observersStopped=true childrenReaped=true")
    }
}
