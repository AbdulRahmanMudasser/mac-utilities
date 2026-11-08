import Darwin
import Foundation

nonisolated struct TranscriptionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let savedAt: Date

    init(id: UUID = UUID(), text: String, savedAt: Date) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
    }
}

nonisolated private struct TranscriptionHistoryDocument: Codable, Sendable {
    let schemaVersion: Int
    let entries: [TranscriptionHistoryEntry]
}

@MainActor
final class TranscriptionHistoryStore {
    nonisolated enum StorageError: Error, Equatable, LocalizedError {
        case loadRequired
        case invalidHistory
        case unsupportedSchema(Int)
        case invalidTimestamp
        case emptyTranscript
        case invalidFileURL
        case unsafeStorageDirectory
        case unsafeHistoryFile
        case fileSystem(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .loadRequired:
                "Transcription history must load successfully before it can be changed."
            case .invalidHistory:
                "The saved transcription history is invalid. The file has been kept."
            case .unsupportedSchema(let version):
                "The saved transcription history uses unsupported format version \(version). The file has been kept."
            case .invalidTimestamp:
                "Transcription history could not be saved because its timestamp is invalid."
            case .emptyTranscript:
                "Only completed, non-empty transcriptions can be saved to History."
            case .invalidFileURL:
                "Transcription history must use an absolute local file URL."
            case .unsafeStorageDirectory:
                "Transcription history storage must be a private directory, not a symbolic link or file."
            case .unsafeHistoryFile:
                "The saved transcription history must be a regular file, not a symbolic link or directory."
            case .fileSystem(let operation, let code):
                "Transcription history could not \(operation) (system error \(code))."
            }
        }
    }

    nonisolated private static let currentSchemaVersion = 1

    let historyURL: URL
    private let now: @MainActor () -> Date
    private(set) var entries: [TranscriptionHistoryEntry] = []
    private var loadedSuccessfully = false

    init(historyURL: URL, now: @escaping @MainActor () -> Date = Date.init) {
        self.historyURL = historyURL
        self.now = now
    }

    @discardableResult
    func load() throws -> [TranscriptionHistoryEntry] {
        do {
            let loadedEntries = try Self.readEntries(at: historyURL)
            entries = loadedEntries
            loadedSuccessfully = true
            return loadedEntries
        } catch {
            loadedSuccessfully = false
            throw error
        }
    }

    @discardableResult
    func append(_ text: String) throws -> TranscriptionHistoryEntry {
        try requireSuccessfulLoad()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageError.emptyTranscript
        }

        let savedAt = now()
        guard savedAt.timeIntervalSince1970.isFinite else {
            throw StorageError.invalidTimestamp
        }

        var entry = TranscriptionHistoryEntry(text: text, savedAt: savedAt)
        while entries.contains(where: { $0.id == entry.id }) {
            entry = TranscriptionHistoryEntry(text: text, savedAt: savedAt)
        }

        var updatedEntries = entries
        updatedEntries.append(entry)
        try Self.write(updatedEntries, to: historyURL)
        entries = updatedEntries
        return entry
    }

    func delete(id: UUID) throws {
        try requireSuccessfulLoad()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        var updatedEntries = entries
        updatedEntries.remove(at: index)
        try Self.write(updatedEntries, to: historyURL)
        entries = updatedEntries
    }

    func clear() throws {
        try requireSuccessfulLoad()
        guard !entries.isEmpty else { return }

        try Self.write([], to: historyURL)
        entries = []
    }

    private func requireSuccessfulLoad() throws {
        guard loadedSuccessfully else { throw StorageError.loadRequired }
    }

    nonisolated private static func readEntries(at url: URL) throws -> [TranscriptionHistoryEntry] {
        try preparePrivateDirectory(at: url.deletingLastPathComponent())
        guard let data = try readProtectedFile(at: url) else { return [] }

        return try validatedEntries(in: data)
    }

    nonisolated static func validatedEntries(in data: Data) throws -> [TranscriptionHistoryEntry] {
        let document: TranscriptionHistoryDocument
        do {
            document = try JSONDecoder().decode(TranscriptionHistoryDocument.self, from: data)
        } catch {
            throw StorageError.invalidHistory
        }

        guard document.schemaVersion == currentSchemaVersion else {
            throw StorageError.unsupportedSchema(document.schemaVersion)
        }
        try validate(document.entries)
        return document.entries
    }

    nonisolated private static func write(_ entries: [TranscriptionHistoryEntry], to url: URL) throws {
        try validate(entries)
        let document = TranscriptionHistoryDocument(schemaVersion: currentSchemaVersion, entries: entries)
        let data = try JSONEncoder().encode(document)
        try preparePrivateDirectory(at: url.deletingLastPathComponent())
        try writeProtectedFile(data, to: url)
    }

    nonisolated private static func validate(_ entries: [TranscriptionHistoryEntry]) throws {
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      $0.savedAt.timeIntervalSince1970.isFinite
              }) else {
            throw StorageError.invalidHistory
        }
    }

    nonisolated private static func readProtectedFile(at url: URL) throws -> Data? {
        guard isAbsoluteFileURL(url) else { throw StorageError.invalidFileURL }

        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            if errno == ELOOP { throw StorageError.unsafeHistoryFile }
            throw fileSystemError("open the saved history", errno)
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw fileSystemError("inspect the saved history", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw StorageError.unsafeHistoryFile
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw fileSystemError("secure the saved history", errno)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("read the saved history", errno)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    nonisolated private static func preparePrivateDirectory(at url: URL) throws {
        guard isAbsoluteFileURL(url) else { throw StorageError.invalidFileURL }

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            var info = stat()
            let result = url.path.withCString { lstat($0, &info) }
            guard result == 0 else { throw error }
        }

        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else { throw fileSystemError("inspect the storage directory", errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageError.unsafeStorageDirectory
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw fileSystemError("secure the storage directory", errno)
        }
    }

    nonisolated private static func writeProtectedFile(_ data: Data, to url: URL) throws {
        guard isAbsoluteFileURL(url) else { throw StorageError.invalidFileURL }

        var destinationInfo = stat()
        let destinationResult = url.path.withCString { lstat($0, &destinationInfo) }
        if destinationResult == 0 {
            guard (destinationInfo.st_mode & S_IFMT) == S_IFREG else {
                throw StorageError.unsafeHistoryFile
            }
        } else if errno != ENOENT && errno != ENOTDIR {
            throw fileSystemError("inspect the history destination", errno)
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".history-\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw fileSystemError("create a protected history file", errno)
        }

        var descriptorOpen = true
        var removeTemporaryFile = true
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if removeTemporaryFile { _ = unlink(temporaryURL.path) }
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            throw fileSystemError("secure the new history file", errno)
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    bytes.count - bytesWritten
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw fileSystemError("write the saved history", errno)
                }
                guard result > 0 else {
                    throw StorageError.fileSystem(operation: "write the saved history", code: EIO)
                }
                bytesWritten += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw fileSystemError("flush the saved history", errno)
        }
        guard close(descriptor) == 0 else {
            descriptorOpen = false
            throw fileSystemError("close the saved history", errno)
        }
        descriptorOpen = false

        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in rename(sourcePath, destinationPath) }
        }
        guard renameResult == 0 else {
            throw fileSystemError("publish the saved history", errno)
        }
        removeTemporaryFile = false

        let directoryDescriptor = url.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY)
        }
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            _ = close(directoryDescriptor)
        }
    }

    nonisolated private static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/")
    }

    nonisolated private static func fileSystemError(_ operation: String, _ code: Int32) -> StorageError {
        .fileSystem(operation: operation, code: code)
    }
}
