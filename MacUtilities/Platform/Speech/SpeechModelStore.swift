import CryptoKit
import Darwin
import Foundation

nonisolated enum SpeechModelStoreError: Error, Equatable, LocalizedError, Sendable {
    case modelUnavailable(languageCode: String, reason: SpeechModelUnavailableReason)
    case assetUnavailable(asset: SpeechModelAsset, reason: SpeechModelUnavailableReason)
    case invalidFileURL
    case unsafeStorageDirectory
    case unsafeSourceFile
    case unsafeDestination
    case sourceByteCountMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case modelNotInstalled
    case installedModelInvalid
    case stagedModelInvalid
    case assetInUse
    case fileSystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let languageCode, let reason):
            switch reason {
            case .trustedPinnedMetadataMissing:
                "The \(languageCode) speech model is unavailable because trusted pinned metadata has not been established."
            case .unsupportedLanguageCode:
                "No speech model is configured for language code \(languageCode)."
            case .invalidPinnedMetadata:
                "The pinned speech model metadata is invalid."
            }
        case .assetUnavailable(let asset, let reason):
            switch reason {
            case .trustedPinnedMetadataMissing:
                "The \(asset.displayName) is unavailable because trusted pinned metadata has not been established."
            case .unsupportedLanguageCode:
                "No speech asset is configured for the \(asset.displayName)."
            case .invalidPinnedMetadata:
                "The pinned \(asset.displayName) metadata is invalid."
            }
        case .invalidFileURL:
            "Speech model storage and import sources must use local file URLs."
        case .unsafeStorageDirectory:
            "Speech model storage must be a private directory, not a symbolic link or file."
        case .unsafeSourceFile:
            "The imported speech model must be a regular file, not a symbolic link or directory."
        case .unsafeDestination:
            "The existing speech model destination is not a regular file."
        case .sourceByteCountMismatch(let expected, let actual):
            "The imported speech model has \(actual) bytes; the pinned model requires \(expected)."
        case .checksumMismatch:
            "The imported speech model does not match the pinned SHA-256 checksum."
        case .modelNotInstalled:
            "The selected speech model has not been imported."
        case .installedModelInvalid:
            "The installed speech model does not match its pinned size and checksum."
        case .stagedModelInvalid:
            "The staged speech model failed verification and was not installed."
        case .assetInUse:
            "The speech model is currently in use or being updated and cannot be replaced."
        case .fileSystem(let operation, let code):
            "Speech model storage failed during \(operation) (system error \(code))."
        }
    }
}

nonisolated enum SpeechModelImportResult: Equatable, Sendable {
    case installed
    case alreadyCurrent
}

actor SpeechModelStore {
    private let rootURL: URL
    private let catalog: SpeechModelCatalog

    init(rootURL: URL, catalog: SpeechModelCatalog = .pinned) {
        self.rootURL = rootURL.standardizedFileURL
        self.catalog = catalog
    }

    func importModel(
        forLanguageCode languageCode: String,
        from sourceURL: URL
    ) throws -> SpeechModelImportResult {
        try importModel(
            for: .transcription(languageCode: languageCode),
            from: sourceURL
        )
    }

    func importModel(
        for asset: SpeechModelAsset,
        from sourceURL: URL
    ) throws -> SpeechModelImportResult {
        try Task.checkCancellation()
        let metadata = try requireMetadata(for: asset)
        guard SpeechModelFileSystem.isAbsoluteFileURL(rootURL),
              SpeechModelFileSystem.isAbsoluteFileURL(sourceURL) else {
            throw SpeechModelStoreError.invalidFileURL
        }

        try SpeechModelFileSystem.preparePrivateDirectory(rootURL)
        let destinationURL = rootURL.appendingPathComponent(metadata.fileName, isDirectory: false)
        let lockURL = SpeechModelFileSystem.lockURL(for: metadata, in: rootURL)
        let lockDescriptor = try SpeechModelFileSystem.acquireLock(at: lockURL, exclusive: true)
        defer { SpeechModelFileSystem.releaseLock(lockDescriptor) }

        let stagedURL = rootURL.appendingPathComponent(
            ".\(metadata.fileName).\(UUID().uuidString).partial",
            isDirectory: false
        )
        var stagedFileExists = false
        defer {
            if stagedFileExists {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }

        try SpeechModelFileSystem.copyAndVerify(
            from: sourceURL,
            to: stagedURL,
            metadata: metadata
        )
        stagedFileExists = true

        switch try SpeechModelFileSystem.destinationState(at: destinationURL) {
        case .missing:
            break
        case .regularFile:
            if try SpeechModelFileSystem.matches(destinationURL, metadata: metadata) {
                return .alreadyCurrent
            }
        }

        try Task.checkCancellation()
        try SpeechModelFileSystem.publishAtomically(stagedURL, at: destinationURL)
        stagedFileExists = false
        return .installed
    }

    func withModel<Result: Sendable>(
        forLanguageCode languageCode: String,
        operation: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        try await withModel(
            for: .transcription(languageCode: languageCode),
            operation: operation
        )
    }

    func withModel<Result: Sendable>(
        for asset: SpeechModelAsset,
        operation: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        let metadata = try requireMetadata(for: asset)
        guard SpeechModelFileSystem.isAbsoluteFileURL(rootURL) else {
            throw SpeechModelStoreError.invalidFileURL
        }

        try SpeechModelFileSystem.preparePrivateDirectory(rootURL)
        let lockURL = SpeechModelFileSystem.lockURL(for: metadata, in: rootURL)
        let lockDescriptor = try SpeechModelFileSystem.acquireLock(at: lockURL, exclusive: false)
        defer { SpeechModelFileSystem.releaseLock(lockDescriptor) }

        let modelURL = rootURL.appendingPathComponent(metadata.fileName, isDirectory: false)
        guard try SpeechModelFileSystem.destinationState(at: modelURL) == .regularFile else {
            throw SpeechModelStoreError.modelNotInstalled
        }
        guard try SpeechModelFileSystem.matches(modelURL, metadata: metadata) else {
            throw SpeechModelStoreError.installedModelInvalid
        }

        return try await operation(modelURL)
    }

    private func requireMetadata(for asset: SpeechModelAsset) throws -> SpeechModelMetadata {
        switch catalog.availability(for: asset) {
        case .available(let metadata):
            return metadata
        case .unavailable(let reason):
            switch asset {
            case .transcription(let languageCode):
                throw SpeechModelStoreError.modelUnavailable(languageCode: languageCode, reason: reason)
            case .vad:
                throw SpeechModelStoreError.assetUnavailable(asset: asset, reason: reason)
            }
        }
    }
}

nonisolated enum SpeechModelValidation {
    static func matches(_ url: URL, metadata: SpeechModelMetadata) throws -> Bool {
        try SpeechModelFileSystem.matches(url, metadata: metadata)
    }
}

nonisolated private enum SpeechModelFileSystem {
    private static let copyBufferSize = 1024 * 1024

    enum DestinationState: Equatable {
        case missing
        case regularFile
    }

    static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/")
    }

    static func preparePrivateDirectory(_ directoryURL: URL) throws {
        guard isAbsoluteFileURL(directoryURL) else { throw SpeechModelStoreError.invalidFileURL }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            var info = stat()
            let result = directoryURL.path.withCString { lstat($0, &info) }
            guard result == 0 else { throw error }
        }

        var info = stat()
        let result = directoryURL.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            throw fileSystemError("inspect storage directory", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SpeechModelStoreError.unsafeStorageDirectory
        }
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw fileSystemError("secure storage directory", errno)
        }
    }

    static func lockURL(for metadata: SpeechModelMetadata, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(".\(metadata.fileName).lock", isDirectory: false)
    }

    static func acquireLock(at url: URL, exclusive: Bool) throws -> Int32 {
        let descriptor = url.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SpeechModelStoreError.unsafeDestination }
            throw fileSystemError("open model lease", errno)
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw fileSystemError("inspect model lease", code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            _ = close(descriptor)
            throw SpeechModelStoreError.unsafeDestination
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw fileSystemError("secure model lease", code)
        }

        let operation = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw SpeechModelStoreError.assetInUse
            }
            throw fileSystemError("acquire model lease", code)
        }
        return descriptor
    }

    static func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func copyAndVerify(
        from sourceURL: URL,
        to stagedURL: URL,
        metadata: SpeechModelMetadata
    ) throws {
        guard isAbsoluteFileURL(sourceURL),
              isAbsoluteFileURL(stagedURL),
              metadata.isWellFormed else {
            throw SpeechModelStoreError.invalidFileURL
        }

        let sourceDescriptor = sourceURL.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP { throw SpeechModelStoreError.unsafeSourceFile }
            throw fileSystemError("open imported model", errno)
        }
        defer { _ = close(sourceDescriptor) }

        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0 else {
            throw fileSystemError("inspect imported model", errno)
        }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SpeechModelStoreError.unsafeSourceFile
        }
        guard sourceInfo.st_size == metadata.expectedByteCount else {
            throw SpeechModelStoreError.sourceByteCountMismatch(
                expected: metadata.expectedByteCount,
                actual: sourceInfo.st_size
            )
        }

        let stagedDescriptor = stagedURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard stagedDescriptor >= 0 else {
            throw fileSystemError("create staged model", errno)
        }
        var stagedDescriptorOpen = true
        var removeStagedFileOnFailure = true
        defer {
            if stagedDescriptorOpen { _ = close(stagedDescriptor) }
            if removeStagedFileOnFailure { _ = unlink(stagedURL.path) }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: copyBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let readCount = read(sourceDescriptor, buffer, copyBufferSize)
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("read imported model", errno)
            }

            totalBytes += Int64(readCount)
            guard totalBytes <= metadata.expectedByteCount else {
                throw SpeechModelStoreError.sourceByteCountMismatch(
                    expected: metadata.expectedByteCount,
                    actual: totalBytes
                )
            }

            let chunk = Data(bytes: buffer, count: readCount)
            hasher.update(data: chunk)
            try writeAll(buffer, count: readCount, to: stagedDescriptor)
        }

        guard totalBytes == metadata.expectedByteCount else {
            throw SpeechModelStoreError.sourceByteCountMismatch(
                expected: metadata.expectedByteCount,
                actual: totalBytes
            )
        }

        let actualDigest = Self.hexString(hasher.finalize())
        guard actualDigest == metadata.sha256 else {
            throw SpeechModelStoreError.checksumMismatch(
                expected: metadata.sha256,
                actual: actualDigest
            )
        }

        guard fsync(stagedDescriptor) == 0 else {
            throw fileSystemError("flush staged model", errno)
        }
        guard close(stagedDescriptor) == 0 else {
            stagedDescriptorOpen = false
            throw fileSystemError("close staged model", errno)
        }
        stagedDescriptorOpen = false

        guard try matches(stagedURL, metadata: metadata) else {
            throw SpeechModelStoreError.stagedModelInvalid
        }
        removeStagedFileOnFailure = false
    }

    static func destinationState(at url: URL) throws -> DestinationState {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw fileSystemError("inspect model destination", code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SpeechModelStoreError.unsafeDestination
        }
        return .regularFile
    }

    static func matches(_ url: URL, metadata: SpeechModelMetadata) throws -> Bool {
        guard metadata.isWellFormed else { return false }
        let (byteCount, digest) = try digestOfRegularFile(at: url)
        return byteCount == metadata.expectedByteCount && digest == metadata.sha256
    }

    static func publishAtomically(_ stagedURL: URL, at destinationURL: URL) throws {
        let result = stagedURL.path.withCString { stagedPath in
            destinationURL.path.withCString { destinationPath in
                rename(stagedPath, destinationPath)
            }
        }
        guard result == 0 else {
            throw fileSystemError("publish verified model", errno)
        }
    }

    private static func digestOfRegularFile(at url: URL) throws -> (Int64, String) {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SpeechModelStoreError.unsafeDestination }
            if errno == ENOENT || errno == ENOTDIR { throw SpeechModelStoreError.modelNotInstalled }
            throw fileSystemError("open model for verification", errno)
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw fileSystemError("inspect model for verification", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SpeechModelStoreError.unsafeDestination
        }

        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: copyBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var totalBytes: Int64 = 0
        while true {
            let readCount = read(descriptor, buffer, copyBufferSize)
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("read model for verification", errno)
            }
            totalBytes += Int64(readCount)
            let chunk = Data(bytes: buffer, count: readCount)
            hasher.update(data: chunk)
        }

        return (totalBytes, Self.hexString(hasher.finalize()))
    }

    private static func writeAll(_ buffer: UnsafeRawPointer, count: Int, to descriptor: Int32) throws {
        var bytesWritten = 0
        while bytesWritten < count {
            let result = write(descriptor, buffer.advanced(by: bytesWritten), count - bytesWritten)
            if result < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("write staged model", errno)
            }
            guard result > 0 else {
                throw SpeechModelStoreError.fileSystem(operation: "write staged model", code: EIO)
            }
            bytesWritten += result
        }
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSystemError(_ operation: String, _ code: Int32) -> SpeechModelStoreError {
        .fileSystem(operation: operation, code: code)
    }
}
