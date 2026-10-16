import SwiftUI

nonisolated enum UsageChartPresentation {
    static let downloadColor = Color.primary.opacity(0.8)
    static let uploadColor = Color.secondary.opacity(0.35)

    static func scale(maximumBytes: UInt64, unit: DataDisplayUnit) -> Double {
        let base = unit == .binary ? 1024.0 : 1000.0
        let gigabyte = base * base * base
        return Double(maximumBytes) >= gigabyte ? gigabyte : base * base
    }

    static func scaleLabel(scale: Double, unit: DataDisplayUnit) -> String {
        if unit == .binary { return scale >= 1_073_741_824 ? "GiB" : "MiB" }
        return scale >= 1_000_000_000 ? "GB" : "MB"
    }
}
