import Foundation
import IOKit.pwr_mgt

nonisolated enum PowerAssertionKind: String, Sendable {
    case systemIdle
    case displayIdle

    var assertionName: String {
        switch self {
        case .systemIdle:
            "Mac Utilities Keep Awake - Idle System Sleep"
        case .displayIdle:
            "Mac Utilities Keep Awake - Idle Display Sleep"
        }
    }
}

nonisolated struct PowerAssertionID: Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

nonisolated enum PowerAssertionError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimeout
    case createFailed(kind: PowerAssertionKind, status: Int32)
    case releaseFailed(id: PowerAssertionID, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "The power assertion timeout must be a positive finite duration."
        case let .createFailed(kind, status):
            switch kind {
            case .systemIdle:
                "macOS could not create the idle system sleep assertion (IOKit status \(status))."
            case .displayIdle:
                "macOS could not create the idle display sleep assertion (IOKit status \(status))."
            }
        case let .releaseFailed(id, status):
            "macOS could not release power assertion \(id.rawValue) (IOKit status \(status))."
        }
    }
}

@MainActor
protocol PowerAsserting {
    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID
    func release(_ id: PowerAssertionID) throws
}

@MainActor
final class PowerAssertionClient: PowerAsserting {
    typealias CreateAssertion = ([String: Any]) -> (status: IOReturn, assertionID: UInt32)
    typealias ReleaseAssertion = (UInt32) -> IOReturn

    private let createAssertion: CreateAssertion
    private let releaseAssertion: ReleaseAssertion

    init(
        createAssertion: @escaping CreateAssertion,
        releaseAssertion: @escaping ReleaseAssertion
    ) {
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
    }

    convenience init() {
        self.init(
            createAssertion: { properties in
                var assertionID: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertionID)
                return (status, assertionID)
            },
            releaseAssertion: { IOPMAssertionRelease($0) }
        )
    }

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval? = nil) throws -> PowerAssertionID {
        if let timeout, (!timeout.isFinite || timeout <= 0) {
            throw PowerAssertionError.invalidTimeout
        }

        let assertionType: String
        switch kind {
        case .systemIdle:
            assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        case .displayIdle:
            assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        }

        var properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: assertionType,
            kIOPMAssertionNameKey as String: kind.assertionName,
            kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn)
        ]

        if let timeout {
            properties[kIOPMAssertionTimeoutKey as String] = NSNumber(value: timeout)
            properties[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionTurnOff as String
        }

        let result = createAssertion(properties)
        guard result.status == kIOReturnSuccess else {
            throw PowerAssertionError.createFailed(kind: kind, status: result.status)
        }
        return PowerAssertionID(rawValue: result.assertionID)
    }

    func release(_ id: PowerAssertionID) throws {
        let status = releaseAssertion(id.rawValue)
        guard status == kIOReturnSuccess else {
            throw PowerAssertionError.releaseFailed(id: id, status: status)
        }
    }
}
