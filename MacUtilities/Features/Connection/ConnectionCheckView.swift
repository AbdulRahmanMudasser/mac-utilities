import SwiftUI

struct ConnectionCheckView: View {
    @EnvironmentObject private var diagnostics: ConnectionDiagnostics
    @State private var confirmLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UtilityScrollContent {
                WiFiQualityView()
                UtilityPanel("Reply Time And Missed Replies", action: AnyView(
                    Button("Check Now") { diagnostics.startLatency() }
                        .buttonStyle(.bordered).disabled(diagnostics.isRunning).handPointer()
                ), description: "We send 10 small messages to each of two servers, one second apart, and count the replies.",
                   showsContent: diagnostics.activity == .latency || !diagnostics.probes.isEmpty || diagnostics.latencyCompletedAt != nil,
                   wrapsContent: false) {
                    ConnectionServerCards { target in
                        quickTargetSummary(target)
                    }
                    if let date = diagnostics.latencyCompletedAt {
                        checkTimestamp(date, succeeded: !diagnostics.probes.contains { $0.error != nil || $0.httpsError != nil })
                    }
                }
                StabilityCheckView()
                UtilityPanel("Internet Speed While Busy", action: AnyView(
                    Button("Run Speed Test") { confirmLoad = true }
                        .buttonStyle(.bordered).disabled(diagnostics.isRunning).handPointer()
                ), description: "Checks reply speed while downloading and uploading. Higher scores mean faster replies. RPM means replies per minute.",
                   showsContent: diagnostics.quality != nil || diagnostics.qualityError != nil || diagnostics.qualityCompletedAt != nil) {
                    if let result = diagnostics.quality {
                        VStack(spacing: UtilityStyle.contentSpacing) {
                            metric("Reply Time Before The Test", milliseconds(result.baseline))
                            metric("Reply Time While Downloading", milliseconds(result.downloadLatency), detail: result.downloadLatencySampleCount.map { "\($0) Readings" })
                            metric("Reply Time While Uploading", milliseconds(result.uploadLatency), detail: result.uploadLatencySampleCount.map { "\($0) Readings" })
                            metric("Download Response Score", rpm(result.downloadRPM))
                            metric("Upload Response Score", rpm(result.uploadRPM))
                            metric("Download Speed", capacity(result.downloadCapacity))
                            metric("Upload Speed", capacity(result.uploadCapacity))
                            metric("Network Used", diagnostics.qualityNetworkName)
                        }
                        .padding(.top, UtilityStyle.contentSpacing)

                    }
                    if let error = diagnostics.qualityError { Text(error).font(UtilityStyle.bodyFont) }
                    if let date = diagnostics.qualityCompletedAt {
                        checkTimestamp(date, succeeded: diagnostics.qualityError == nil)
                    }
                }

            }
            HStack(spacing: UtilityStyle.contentSpacing) {
                if diagnostics.isRunning {
                    ProgressView().controlSize(UtilityStyle.progressControlSize)
                }
                Group {
                    if diagnostics.lastStartedActivity == .stability,
                       let snapshot = diagnostics.stabilitySnapshot {
                        Text("\(diagnostics.message) · \(elapsedTime(snapshot.unobservedDuration)) Missed")
                            .help("Missed is time when the check could not run. This does not mean your internet stopped working.")
                    } else {
                        Text(diagnostics.message)
                    }
                }
                .font(UtilityStyle.bodyFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Spacer()
                if diagnostics.isRunning {
                    Button("Cancel") { diagnostics.cancel() }
                        .buttonStyle(.bordered).handPointer()
                }
            }
            .padding(UtilityStyle.pagePadding)
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .sheet(isPresented: $confirmLoad) {
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                Text("Run The Speed Test?").font(UtilityStyle.headingFont)
                Text("This test transfers data and may briefly slow your internet. Data use varies and counts toward your allowance. Today’s Usage includes it while monitoring is on.")
                Text("It stops within one minute. Cancel anytime.")
                HStack(spacing: UtilityStyle.contentSpacing) {
                    Spacer()
                    Button("Cancel", role: .cancel) { confirmLoad = false }
                        .keyboardShortcut(.cancelAction).handPointer()
                    Button("Start Test") {
                        confirmLoad = false
                        diagnostics.startLoad()
                    }
                    .handPointer()
                }
                .buttonStyle(.bordered)
            }
            .padding(UtilityStyle.pagePadding)
            .frame(width: UtilityStyle.confirmationWidth)
            .font(UtilityStyle.bodyFont)
            .controlSize(UtilityStyle.controlSize)
        }
    }

    private func quickTargetSummary(_ target: ProbeTarget) -> some View {
        let result = diagnostics.probes.first { $0.target.id == target.id }
        let statistics = result?.statistics
        return VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ConnectionReplyMetrics(received: statistics?.received, completed: statistics?.sent,
                missed: statistics?.lost, missedPercent: statistics?.lossPercent,
                median: statistics?.median, minimum: statistics?.minimum, maximum: statistics?.maximum,
                changes: statistics?.jitter, isWaiting: diagnostics.activity == .latency && result == nil,
                changesExplanation: "Shows how much reply times speed up or slow down. This check only tests two servers; a missed reply may not mean there is an internet problem.")
            if let error = result?.error {
                Text(error).font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let https = result?.https {
                metric("Web Check", "Server Replied · Code \(https.statusCode)")
                metric("Web Reply Time", milliseconds(https.elapsedMilliseconds),
                    explanation: "This time includes the server’s work. It does not measure missed test replies.")
            }
            if let error = result?.httpsError {
                Text("Web Check: \(error)").font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ title: String, _ value: String, detail: String? = nil, explanation: String? = nil) -> some View {
        UtilityMetricRow(title: title, value: value, detail: detail, explanation: explanation)
    }

    private func checkTimestamp(_ date: Date, succeeded: Bool) -> some View {
        ConnectionCheckTimestamp(date: date,
            symbol: succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            color: succeeded ? UtilityStyle.successColor : UtilityStyle.warningColor)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ms" } ?? "Not Available"
    }
    private func elapsedTime(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
    private func rpm(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) RPM" } ?? "Not Available"
    }
    private func capacity(_ value: Double?) -> String {
        value.map { "\(($0 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps" } ?? "Not Available"
    }
}
