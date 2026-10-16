import Foundation

nonisolated enum UsageStorageLimits {
    static let maximumEnvelopeBytes = 9 * 1_024 * 1_024
    static let maximumProjectionBytes = 64 * 1_024
    static let maximumRecords = 31
}
