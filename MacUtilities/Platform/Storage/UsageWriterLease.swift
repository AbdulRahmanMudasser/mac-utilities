import Darwin
import Foundation

nonisolated final class UsageWriterLease {
    enum LeaseError: Error, LocalizedError {
        case alreadyLocked
        case openFailed(Int32)
        case lockFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyLocked:
                "Another Mac Utilities process already owns the usage writer lease."
            case .openFailed(let code):
                "The usage writer lease could not be opened: \(String(cString: strerror(code)))."
            case .lockFailed(let code):
                "The usage writer lease could not be acquired: \(String(cString: strerror(code)))."
            }
        }
    }

    private var descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = url.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard opened >= 0 else { throw LeaseError.openFailed(errno) }

        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(opened)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw LeaseError.alreadyLocked
            }
            throw LeaseError.lockFailed(code)
        }
        descriptor = opened
    }

    func close() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}
