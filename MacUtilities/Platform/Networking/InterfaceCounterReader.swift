import Foundation
import Darwin

enum InterfaceCounterReader {
    enum ReaderError: LocalizedError {
        case sysctl(String)
        case noPhysicalInterfaces

        var errorDescription: String? {
            switch self {
            case .sysctl(let message): "Could not read network interface counters: \(message)"
            case .noPhysicalInterfaces: "No active Ethernet or Wi-Fi interface counters are available."
            }
        }
    }

    static func read() throws -> [String: InterfaceByteCount] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0

        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            throw ReaderError.sysctl(String(cString: strerror(errno)))
        }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &length, nil, 0)
        }
        guard result == 0 else {
            throw ReaderError.sysctl(String(cString: strerror(errno)))
        }

        var counters: [String: InterfaceByteCount] = [:]
        var offset = 0
        let minimumMessageSize = MemoryLayout<if_msghdr2>.size

        while offset + MemoryLayout<UInt16>.size + 2 <= length {
            let messageLength = buffer.withUnsafeBytes {
                Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            guard messageLength >= MemoryLayout<UInt16>.size + 2, offset + messageLength <= length else { break }

            let messageType = buffer[offset + 3]
            if messageType == UInt8(RTM_IFINFO2), messageLength >= minimumMessageSize {
                let message = buffer.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                if let interfaceName = name(for: message.ifm_index), isPhysicalInterface(interfaceName) {
                    counters[interfaceName] = InterfaceByteCount(
                        downloaded: message.ifm_data.ifi_ibytes,
                        uploaded: message.ifm_data.ifi_obytes
                    )
                }
            }

            offset += messageLength
        }

        guard !counters.isEmpty else { throw ReaderError.noPhysicalInterfaces }
        return counters
    }

    private static func name(for index: UInt16) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &nameBuffer) != nil else { return nil }
        return String(cString: nameBuffer)
    }

    private static func isPhysicalInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}
