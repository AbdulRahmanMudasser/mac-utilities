import Foundation

nonisolated struct InterfaceByteCount: Codable, Equatable, Sendable {
    var downloaded: UInt64
    var uploaded: UInt64
}

nonisolated enum DataDisplayUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case decimal
    case binary

    var id: String { rawValue }
    var title: String { self == .decimal ? "MB/GB" : "MiB/GiB" }
}
