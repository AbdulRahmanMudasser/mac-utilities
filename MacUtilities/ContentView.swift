import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ratesSection
            totalsSection
            footer
        }
        .padding(16)
        .frame(width: 390)
        .sheet(isPresented: $confirmReset) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reset Today's Counters?").font(.headline)
                Text("Today's observed device totals will restart from zero.")
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { confirmReset = false }
                        .keyboardShortcut(.cancelAction)
                        .handPointer()
                    Button("Reset Today's Counters", role: .destructive) {
                        monitor.resetToday()
                        confirmReset = false
                    }
                    .handPointer()
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(width: 340)
        }
    }

    private var ratesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Current Speed")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
                SpeedValue(title: "Download", value: monitor.formattedDownloadRate)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                SpeedValue(title: "Upload", value: monitor.formattedUploadRate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Today's Usage")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 0) {
                TotalValue(title: "Downloaded", value: monitor.formattedDownloadedToday)
                Spacer(minLength: 8)
                TotalValue(title: "Uploaded", value: monitor.formattedUploadedToday)
                Spacer(minLength: 8)
                TotalValue(title: "Combined", value: monitor.formattedCombinedToday)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

        }
    }

    private var footer: some View {
        HStack {
            Button(action: presentSettings) {
                Text("Settings")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .handPointer()

            Spacer()

            if monitor.isPaused {
                Button("Resume") { monitor.setPaused(false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .handPointer()
            } else {
                Button("Pause") { monitor.setPaused(true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .handPointer()
            }

            Button("Reset") { confirmReset = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .handPointer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .handPointer()
        }
        .font(.caption)
    }

    private func presentSettings() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: AppWindowID.settings)
        NSApp.activate()
    }
}

private struct SpeedValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TotalValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
