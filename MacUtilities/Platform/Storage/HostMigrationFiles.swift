import CryptoKit
import Darwin
import Foundation

nonisolated enum HostMigrationError: Int32, Error, LocalizedError {
    case unsafeInput = 20, activeWriter, invalidSource, insufficientSpace, changedSource, invalidBackup, conflict, cancelled

    var errorDescription: String? {
        switch self {
        case .unsafeInput: "The migration locations or receipt are unsafe. Choose separate private storage locations."
        case .activeWriter: "Quit other Mac Utilities instances before preparing or migrating data."
        case .invalidSource: "Saved data could not be validated. The original files have been kept."
        case .insufficientSpace: "There is not enough free space to back up and migrate saved data."
        case .changedSource: "Saved data changed after backup. Quit the old app and prepare a new backup."
        case .invalidBackup: "The migration backup could not be verified. Prepare a new backup before continuing."
        case .conflict: "Saved data conflicts with the migration receipt. Both versions have been kept for recovery."
        case .cancelled: "Migration was cancelled. Saved data has been kept."
        }
    }
}

nonisolated enum HostMigrationFiles {
    struct Fingerprint: Codable, Equatable, Sendable {
        let bytes: Int64
        let sha256: String
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw HostMigrationError.unsafeInput }
        return false
    }

    static func checkPath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path == url.standardizedFileURL.path else {
            throw HostMigrationError.unsafeInput
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else { throw HostMigrationError.unsafeInput }
                continue
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw HostMigrationError.unsafeInput }
        }
    }

    static func privateDirectory(_ url: URL) throws {
        try checkPath(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), chmod(url.path, 0o700) == 0 else { throw HostMigrationError.unsafeInput }
    }

    static func fingerprint(_ url: URL) throws -> Fingerprint {
        try checkPath(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostMigrationError.invalidSource }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw HostMigrationError.unsafeInput }
        var hasher = SHA256()
        var size: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw HostMigrationError.invalidSource
            }
            size += Int64(count)
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard size == info.st_size else { throw HostMigrationError.changedSource }
        return Fingerprint(bytes: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func data(_ url: URL, maximumBytes: Int = 16 * 1_024 * 1_024) throws -> Data {
        try checkPath(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostMigrationError.invalidSource }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximumBytes else { throw HostMigrationError.invalidSource }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes, bytes.count == info.st_size else { throw HostMigrationError.changedSource }
        return bytes
    }

    static func write(_ data: Data, to url: URL) throws {
        try privateDirectory(url.deletingLastPathComponent())
        try checkPath(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostMigrationError.invalidBackup }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HostMigrationError.invalidBackup }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw HostMigrationError.invalidBackup }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func copy(_ source: URL, to destination: URL, expected: Fingerprint) throws {
        try checkPath(source)
        try privateDirectory(destination.deletingLastPathComponent())
        try checkPath(destination)
        guard !(try exists(destination)) else {
            guard try fingerprint(destination) == expected else { throw HostMigrationError.conflict }
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard chmod(temporary.path, 0o600) == 0, try fingerprint(temporary) == expected,
              try fingerprint(source) == expected else { throw HostMigrationError.changedSource }
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostMigrationError.invalidBackup }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw HostMigrationError.invalidBackup }
        // link fails if another process publishes the destination; it never replaces it.
        guard link(temporary.path, destination.path) == 0 else { throw HostMigrationError.conflict }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostMigrationError.invalidBackup }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw HostMigrationError.invalidBackup }
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/")
    }
}
