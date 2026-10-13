import SwiftUI

struct ConnectionCheckView: View {
    @EnvironmentObject private var diagnostics: ConnectionDiagnostics
    @State private var confirmLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UtilityScrollContent {
                UtilityPanel("Reply Time And Missed Replies", action: AnyView(
                    Button("Check Now") { diagnostics.startLatency() }
                        .buttonStyle(.bordered).disabled(diagnostics.isRunning).handPointer()
                )) {
                    Text("We send 10 small messages to Google and Cloudflare, one second apart. We check how many come back.")
                        .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                        .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(diagnostics.probes) { result in
                        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                            Text("\(result.target.name) · \(result.target.address)").font(UtilityStyle.bodyFont.weight(.semibold))
                            if let statistics = result.statistics {
                                metric("Replies", "\(statistics.received) Of \(statistics.sent)")
                                if statistics.received == 0 {
                                    Text("This Server Did Not Reply.").font(UtilityStyle.bodyFont)
                                } else {
                                    metric("Missed Test Replies", "\(statistics.lost) Of \(statistics.sent) (\(statistics.lossPercent.formatted(.number.precision(.fractionLength(0))))%)")
                                    metric("Typical Reply Time", milliseconds(statistics.median))
                                    metric("Fastest / Slowest Reply", "\(milliseconds(statistics.minimum)) / \(milliseconds(statistics.maximum))")
                                    metric("Reply Time Changes", milliseconds(statistics.jitter))
                                }
                            }
                            if let error = result.error { Text(error).font(UtilityStyle.bodyFont) }
                            if let https = result.https {
                                Divider()
                                metric("Web Check", "Server Replied · Code \(https.statusCode)")
                                metric("Web Reply Time", milliseconds(https.elapsedMilliseconds))
                                Text("This time includes the server’s work. It does not measure missed test replies.")
                                    .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                                    .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = result.httpsError {
                                Text("Web Check: \(error)").font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                                .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, UtilityStyle.contentSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let date = diagnostics.latencyCompletedAt {
                        checkTimestamp(date)
                    }
                    Text("Reply Time Changes shows how much the reply time varies. These short checks only test the two named servers. Missed replies do not always mean your internet is broken.")
                        .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                        .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UtilityPanel("Internet Speed While Busy", action: AnyView(
                    Button("Run Speed Test") { confirmLoad = true }
                        .buttonStyle(.bordered).disabled(diagnostics.isRunning).handPointer()
                )) {
                    Text("This test checks how quickly your internet replies while sending and receiving data. A higher response score means quicker replies while busy. RPM means replies per minute.")
                        .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                        .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
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
                        checkTimestamp(date)
                    }
                }

            }
            HStack(spacing: UtilityStyle.contentSpacing) {
                if diagnostics.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(diagnostics.message)
                    .font(UtilityStyle.bodyFont)
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
        .controlSize(.regular)
        .sheet(isPresented: $confirmLoad) {
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                Text("Run The Speed Test?").font(UtilityStyle.headingFont)
                Text("This test sends and receives data. It may slow your internet for a short time and use your data allowance. Test data adds to Today’s Usage. Data use can vary. The test has a one-minute time limit. You can cancel at any time.")
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
            .frame(width: 420)
            .font(UtilityStyle.bodyFont)
            .controlSize(.regular)
        }
    }

    private func metric(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: UtilityStyle.contentSpacing)
            HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) {
                Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
                if let detail {
                    Text("· \(detail)").font(UtilityStyle.metadataFont).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(UtilityStyle.bodyFont)
        .accessibilityElement(children: .combine)
    }

    private func checkTimestamp(_ date: Date) -> some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Text("Last Checked")
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(UtilityStyle.metadataFont)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ms" } ?? "Not Available"
    }
    private func rpm(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) RPM" } ?? "Not Available"
    }
    private func capacity(_ value: Double?) -> String {
        value.map { "\(($0 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps" } ?? "Not Available"
    }
}
