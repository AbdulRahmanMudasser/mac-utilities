import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct ConnectionDiagnosticsTests {
    @Test func networkNamesUseSystemMappingWithoutAssumingWiFi() {
        #expect(NetworkInterfaceLabel.displayName("en0", names: ["en0": "Wi-Fi"]) == "Wi-Fi")
        #expect(NetworkInterfaceLabel.displayName("en0", names: ["en0": "Ethernet"]) == "Ethernet")
        #expect(NetworkInterfaceLabel.displayName("utun3", names: [:]) == "Network Interface (utun3)")
        #expect(NetworkInterfaceLabel.displayName(nil, names: [:]) == "Not Reported")
        #expect(NetworkInterfaceLabel.displayName("", names: [:]) == "Not Reported")
    }

    @Test func statisticsUseUniqueReplySamplesAndMedian() throws {
        let output = """
        64 bytes from 8.8.8.8: icmp_seq=0 ttl=52 time=10.000 ms
        64 bytes from 8.8.8.8: icmp_seq=1 ttl=52 time=30.000 ms
        64 bytes from 8.8.8.8: icmp_seq=1 ttl=52 time=30.000 ms (DUP!)
        64 bytes from 8.8.8.8: icmp_seq=3 ttl=52 time=20.000 ms
        4 packets transmitted, 3 packets received, 25.0% packet loss
        """
        let result = try ProbeStatistics.parse(output)
        #expect(result.sent == 4)
        #expect(result.received == 3)
        #expect(result.lost == 1)
        #expect(result.lossPercent == 25)
        #expect(result.minimum == 10)
        #expect(result.maximum == 30)
        #expect(result.median == 20)
        #expect(result.jitter == 15)
    }

    @Test func zeroRepliesHaveNoLatencyOrJitter() throws {
        let result = try ProbeStatistics.parse("10 packets transmitted, 0 packets received, 100.0% packet loss", exitCode: 2)
        #expect(result.received == 0)
        #expect(result.median == nil)
        #expect(result.jitter == nil)
        #expect(result.lost == 10)
    }

    @Test func expectedProbeCountAcceptsOneReplyOnlyForOneProbe() throws {
        let output = """
        64 bytes from 8.8.8.8: icmp_seq=0 ttl=52 time=12.500 ms
        1 packets transmitted, 1 packets received, 0.0% packet loss
        """
        let result = try ProbeStatistics.parse(output, expectedCount: 1)
        #expect(result.sent == 1)
        #expect(result.received == 1)
        #expect(result.samples == [12.5])
        #expect(throws: (any Error).self) {
            try ProbeStatistics.parse(output, expectedCount: 10)
        }
    }

    @Test func receivedSummaryWithoutRTTIsRejected() {
        let delayedReplySummary = "1 packets transmitted, 1 packets received, 0.0% packet loss"
        #expect(throws: (any Error).self) {
            try ProbeStatistics.parse(delayedReplySummary, expectedCount: 1)
        }
    }

    @Test func zeroReplySummaryWithErrorExitIsRejected() {
        #expect(throws: (any Error).self) {
            try ProbeStatistics.parse("10 packets transmitted, 0 packets received, 100.0% packet loss", exitCode: 77)
        }
    }

    @Test func evenMedianAndOneSampleJitter() {
        #expect(ProbeStatistics(sent: 4, received: 4, samples: [12, 2, 8, 4]).median == 6)
        #expect(ProbeStatistics(sent: 1, received: 1, samples: [12]).jitter == nil)
    }

    @Test(arguments: ["", "socket: Operation not permitted", "2 packets transmitted, 3 packets received", "0 packets transmitted, 0 packets received", "11 packets transmitted, 1 packets received", "1 packets transmitted, 1 packets received"])
    func malformedProbeOutputsAreRejected(_ output: String) {
        #expect(throws: (any Error).self) { try ProbeStatistics.parse(output) }
    }

    @Test func qualityKeepsMissingMeasurementsAbsent() throws {
        let json = Data(#"{"base_rtt":12.5,"dl_throughput":12000000,"dl_responsiveness":800,"interface_name":"en0"}"#.utf8)
        let result = try QualityResult.parse(json, exitCode: 0)
        #expect(result.baseline == 12.5)
        #expect(result.downloadCapacity == 12_000_000)
        #expect(result.downloadRPM == 800)
        #expect(result.uploadCapacity == nil)
        #expect(result.uploadLatency == nil)
        #expect(result.interfaceName == "en0")
    }

    @Test func qualityParsesDirectionalLoadedMetrics() throws {
        let json = Data(#"{"base_rtt":5,"lud_foreign_dl_h2_req_resp":20,"lud_foreign_ul_h2_req_resp":40,"dl_throughput":1000000,"ul_throughput":2000000,"dl_responsiveness":3000,"ul_responsiveness":1500}"#.utf8)
        let result = try QualityResult.parse(json, exitCode: 0)
        #expect(result.downloadLatency == 20)
        #expect(result.uploadLatency == 40)
        #expect(result.uploadRPM == 1500)
    }

    @Test(arguments: ["{}", "[]", "bad JSON", #"{"base_rtt":true}"#, #"{"base_rtt":-1}"#, #"{"base_rtt":"5"}"#, #"{"base_rtt":5,"error_domain":"Test","error_code":7}"#])
    func invalidOrFailedQualityIsRejected(_ json: String) {
        #expect(throws: (any Error).self) { try QualityResult.parse(Data(json.utf8), exitCode: 0) }
    }

    @Test func actualSystemLatencyArrayShapeUsesMedianAndSampleCount() throws {
        let json = Data(#"{"base_rtt":200,"lud_foreign_dl_h2_req_resp":[200,300,400,800],"lud_foreign_ul_h2_req_resp":[100,200,900]}"#.utf8)
        let result = try QualityResult.parse(json, exitCode: 0)
        #expect(result.downloadLatency == 350)
        #expect(result.downloadLatencySampleCount == 4)
        #expect(result.uploadLatency == 200)
        #expect(result.uploadLatencySampleCount == 3)
    }

    @Test func emptyLatencyArrayRemainsUnavailable() throws {
        let result = try QualityResult.parse(Data(#"{"base_rtt":20,"lud_foreign_dl_h2_req_resp":[]}"#.utf8), exitCode: 0)
        #expect(result.downloadLatency == nil)
        #expect(result.downloadLatencySampleCount == nil)
    }

    @Test(arguments: [#"{"base_rtt":20,"lud_foreign_dl_h2_req_resp":[true]}"#, #"{"base_rtt":20,"lud_foreign_dl_h2_req_resp":[-1]}"#, #"{"base_rtt":20,"lud_foreign_dl_h2_req_resp":["20"]}"#])
    func invalidLatencyArrayIsRejected(_ json: String) {
        #expect(throws: (any Error).self) { try QualityResult.parse(Data(json.utf8), exitCode: 0) }
    }

    @Test func failedExitNeverLooksSuccessful() {
        #expect(throws: (any Error).self) { try QualityResult.parse(Data(#"{"base_rtt":5}"#.utf8), exitCode: 1) }
    }

    @Test func processReturnsOutputAndExitCode() async throws {
        let runner = DiagnosticProcessRunner()
        let output = try await runner.run(executable: "/usr/bin/printf", arguments: ["fixture"], timeout: 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "fixture")
        #expect(output.exitCode == 0)
        #expect(runner.activeProcessIDs.isEmpty)
        let failed = try await runner.run(executable: "/usr/bin/false", arguments: [], timeout: 3)
        #expect(failed.exitCode != 0)
    }

    @Test func processTimeoutReapsChild() async {
        let runner = DiagnosticProcessRunner()
        do {
            _ = try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch let failure as DiagnosticProcessFailure {
            #expect(failure.message == DiagnosticError.timeout.localizedDescription)
            #expect(failure.stderrDetail == nil)
        }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(runner.activeProcessIDs.isEmpty)
    }

    @Test func processFailureCarriesItsOwnStandardErrorDetail() async {
        let runner = DiagnosticProcessRunner()
        do {
            _ = try await runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'operation detail\\n' >&2; exec /bin/sleep 5"],
                timeout: 0.2,
                operationID: UUID()
            )
            Issue.record("Expected timeout")
        } catch let failure as DiagnosticProcessFailure {
            #expect(failure.message == DiagnosticError.timeout.localizedDescription)
            #expect(failure.stderrDetail == "operation detail")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(runner.activeProcessIDs.isEmpty)
    }

    @Test func processCancellationReapsChild() async throws {
        let runner = DiagnosticProcessRunner()
        let operationID = UUID()
        let task = Task { try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 10, operationID: operationID) }
        try await Task.sleep(for: .milliseconds(150))
        let pids = runner.activeProcessIDs
        #expect(!pids.isEmpty)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(runner.activeProcessIDs.isEmpty)
        for pid in pids { #expect(kill(pid, 0) == -1) }
    }

    @Test func stopOnlyKillsProcessesTaggedWithRequestedOperationIDs() async throws {
        let runner = DiagnosticProcessRunner()
        let stoppedOperationID = UUID()
        let continuingOperationID = UUID()
        let stopped = Task {
            try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 10, operationID: stoppedOperationID)
        }
        let continuing = Task {
            try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 10, operationID: continuingOperationID)
        }
        for _ in 0..<100 {
            if runner.activeProcessIDs.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pids = runner.activeProcessIDs
        #expect(pids.count == 2)
        runner.stop(operationIDs: [stoppedOperationID])
        for _ in 0..<100 {
            if runner.activeProcessIDs.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let remainingPIDs = runner.activeProcessIDs
        #expect(remainingPIDs.count == 1)
        if let remainingPID = remainingPIDs.first {
            #expect(kill(remainingPID, 0) == 0)
            runner.stop(operationIDs: [continuingOperationID])
            _ = try? await stopped.value
            _ = try? await continuing.value
            #expect(runner.activeProcessIDs.isEmpty)
            #expect(kill(remainingPID, 0) == -1)
        } else {
            runner.stopAll()
            _ = try? await stopped.value
            _ = try? await continuing.value
            Issue.record("Expected the unrelated operation to remain active")
        }
    }

    @Test func missingExecutableFailsWithoutLeavingChild() async {
        let runner = DiagnosticProcessRunner()
        do {
            _ = try await runner.run(executable: "/does-not-exist/mac-utilities-test", arguments: [], timeout: 1)
            Issue.record("Expected launch failure")
        } catch let failure as DiagnosticProcessFailure {
            #expect(!failure.message.isEmpty)
            #expect(failure.stderrDetail == nil)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(runner.activeProcessIDs.isEmpty)
    }

    @Test func oversizedOutputIsRejected() async {
        let runner = DiagnosticProcessRunner()
        do {
            _ = try await runner.run(executable: "/usr/bin/head", arguments: ["-c", "1048577", "/dev/zero"], timeout: 3)
            Issue.record("Expected output limit")
        } catch let failure as DiagnosticProcessFailure {
            #expect(failure.message == DiagnosticError.outputLimit.localizedDescription)
        }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(runner.activeProcessIDs.isEmpty)
    }
    private func waitUntilIdle(_ diagnostics: ConnectionDiagnostics) async throws {
        for _ in 0..<100 {
            if !diagnostics.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Diagnostic controller did not return to idle")
    }

    @Test func controllerKeepsNoReplyAndHTTPSResultsSeparate() async throws {
        var httpsCalls = 0
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            DiagnosticProcessOutput(stdout: Data("10 packets transmitted, 0 packets received, 100.0% packet loss".utf8), stderr: Data(), exitCode: 2)
        }, httpsOperation: { _ in
            httpsCalls += 1
            return HTTPSResult(elapsedMilliseconds: 200, statusCode: 200)
        })
        diagnostics.startLatency()
        try await waitUntilIdle(diagnostics)
        #expect(diagnostics.probes.map(\.target.address) == ["8.8.8.8", "1.1.1.1"])
        #expect(diagnostics.probes.allSatisfy { $0.statistics?.received == 0 && $0.https?.statusCode == 200 && $0.error == nil })
        #expect(httpsCalls == 2)
        #expect(diagnostics.latencyCompletedAt != nil)
    }

    @Test func controllerCancellationAndMutualExclusionIgnoreLateResults() async throws {
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return DiagnosticProcessOutput(stdout: Data(#"{"base_rtt":5}"#.utf8), stderr: Data(), exitCode: 0)
        })
        diagnostics.startLoad()
        diagnostics.startLatency()
        #expect(diagnostics.activity == .load)
        diagnostics.cancel()
        try await waitUntilIdle(diagnostics)
        #expect(diagnostics.quality == nil)
        #expect(diagnostics.probes.isEmpty)
        #expect(diagnostics.qualityCompletedAt == nil)
        #expect(diagnostics.message == "Check Cancelled.")
    }

    @Test func controllerShowsFailedMeasurementWithoutFakeValues() async throws {
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            DiagnosticProcessOutput(stdout: Data(#"{"error_domain":"Test","error_code":8}"#.utf8), stderr: Data(), exitCode: 1)
        })
        diagnostics.startLoad()
        try await waitUntilIdle(diagnostics)
        #expect(diagnostics.quality == nil)
        #expect(diagnostics.qualityError?.contains("Error code 8") == true)
        #expect(diagnostics.message == "The Check Could Not Finish.")
    }

}
