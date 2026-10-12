import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "network.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Utilities")
                        .font(.headline)
                    Text("Network activity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("Needs Setup", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("CURRENT SPEED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    RateCard(title: "Download", symbol: "arrow.down", tint: .blue)
                    RateCard(title: "Upload", symbol: "arrow.up", tint: .purple)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("TODAY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    TotalValue(title: "Downloaded")
                    Spacer(minLength: 8)
                    TotalValue(title: "Uploaded")
                    Spacer(minLength: 8)
                    TotalValue(title: "Combined")
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Top apps")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("TODAY")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("App usage will appear after network monitoring is configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("This starter app is not collecting network data yet.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 370)
    }
}

private struct RateCard: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text("—")
                .font(.title2.monospacedDigit().weight(.medium))
            Text("Mbps")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TotalValue: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("—")
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
