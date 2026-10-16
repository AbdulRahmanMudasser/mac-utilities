import Foundation

nonisolated enum UsageFormatting {
    static func data(_ bytes: UInt64, unit: DataDisplayUnit) -> String {
        let base = unit == .decimal ? 1_000.0 : 1_024.0
        let mega = base * base
        let giga = mega * base
        let value = Double(bytes)
        if value >= giga {
            return String(format: "%.2f %@", locale: Locale.current, value / giga, unit == .decimal ? "GB" : "GiB")
        }
        return String(format: "%.1f %@", locale: Locale.current, value / mega, unit == .decimal ? "MB" : "MiB")
    }
}
