import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: UsageMonitor
    @EnvironmentObject private var utilityWindow: UtilityWindowCoordinator
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.Popover.sectionSpacing) {
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text("Connection Health")
                    .font(UtilityStyle.headingFont)
                Spacer()
                Button("Check") {
                    utilityWindow.present(.connection)
                }
                .buttonStyle(.bordered)
                .controlSize(UtilityStyle.Popover.controlSize)
                .handPointer()
            }
            ratesSection
            totalsSection
            footer
        }
        .font(UtilityStyle.bodyFont)
        .padding(UtilityStyle.Popover.pagePadding)
        .frame(width: UtilityStyle.Popover.width)
        .background(MenuBarPopoverWindowAccessor(coordinator: utilityWindow))
        .sheet(isPresented: $confirmReset) {
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                Text("Reset Today's Counters?").font(UtilityStyle.headingFont)
                Text("Today's counters will restart from zero. Chart history stays unchanged.")
                HStack(spacing: UtilityStyle.contentSpacing) {
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
            .font(UtilityStyle.bodyFont)
            .padding(UtilityStyle.pagePadding)
            .frame(width: UtilityStyle.Popover.confirmationWidth)
        }
    }

    private var ratesSection: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.Popover.sectionContentSpacing) {
            Text("Current Speed")
                .font(UtilityStyle.headingFont)

            HStack(spacing: UtilityStyle.contentSpacing) {
                SpeedValue(title: "Download", value: monitor.formattedDownloadRate)
                Rectangle()
                    .fill(.separator)
                    .frame(width: UtilityStyle.Popover.dividerWidth, height: UtilityStyle.Popover.dividerHeight)
                SpeedValue(title: "Upload", value: monitor.formattedUploadRate)
            }
            .padding(UtilityStyle.Popover.cardPadding)
            .utilityCardBackground()
        }
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.Popover.sectionContentSpacing) {
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text("Today's Usage")
                    .font(UtilityStyle.headingFont)
                Spacer()
                Button("Usage") { utilityWindow.present(.usage) }
                    .buttonStyle(.bordered)
                    .controlSize(UtilityStyle.Popover.controlSize)
                    .handPointer()
            }

            HStack(spacing: 0) {
                UtilityTotalValue(title: "Downloaded", value: monitor.formattedDownloadedToday)
                Spacer(minLength: UtilityStyle.Popover.columnSpacing)
                UtilityTotalValue(title: "Uploaded", value: monitor.formattedUploadedToday)
                Spacer(minLength: UtilityStyle.Popover.columnSpacing)
                UtilityTotalValue(title: "Combined", value: monitor.formattedCombinedToday)
            }
            .padding(UtilityStyle.Popover.cardPadding)
            .utilityCardBackground()

        }
    }

    private var footer: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Button(action: presentSettings) {
                Text("Settings")
            }
            .buttonStyle(.bordered)
            .controlSize(UtilityStyle.Popover.controlSize)
            .handPointer()

            Spacer()

            Button("Reset") { confirmReset = true }
                .buttonStyle(.bordered)
                .controlSize(UtilityStyle.Popover.controlSize)
                .handPointer()

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
                .buttonStyle(.bordered)
                .controlSize(UtilityStyle.Popover.controlSize)
                .help("Quit")
                .accessibilityLabel("Quit")
                .handPointer()
        }
        .font(UtilityStyle.Popover.labelFont)
    }

    private func presentSettings() {
        utilityWindow.present(.settings)
    }
}

private struct SpeedValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: UtilityStyle.Popover.rowSpacing) {
            Text(title)
                .font(UtilityStyle.Popover.labelFont)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(value)
                .font(UtilityStyle.Popover.valueFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
