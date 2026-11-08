import Foundation

nonisolated struct TranscriptionStoragePaths: Sendable {
    let supportRoot: URL
    var transcribe: URL { supportRoot.appendingPathComponent("Transcribe", isDirectory: true) }
    var receipt: URL { supportRoot.appendingPathComponent("Migration/host-storage-v1.json") }

    static func resolve(fileManager: FileManager = .default) throws -> Self {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false)
        return Self(supportRoot: support.appendingPathComponent("MacUtilities", isDirectory: true))
    }
}
