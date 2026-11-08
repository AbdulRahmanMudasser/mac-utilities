import CryptoKit
import Foundation

nonisolated enum HostMigrationValidation {
    static func isModelPath(_ path: String) -> Bool {
        [SpeechModelMetadata.pinnedEnglish, .pinnedUrdu, .pinnedVAD].contains { path == "Models/" + $0.fileName }
    }

    static func validate(_ url: URL, relativePath: String) throws {
        if relativePath == "history.json" {
            _ = try TranscriptionHistoryStore.validatedEntries(in: HostMigrationFiles.data(url))
            return
        }
        let metadata = [SpeechModelMetadata.pinnedEnglish, .pinnedUrdu, .pinnedVAD]
        guard let model = metadata.first(where: { relativePath == "Models/" + $0.fileName }),
              try SpeechModelValidation.matches(url, metadata: model) else { throw HostMigrationError.invalidSource }
    }

    static func fingerprint(_ data: Data) -> HostMigrationFiles.Fingerprint {
        .init(bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
