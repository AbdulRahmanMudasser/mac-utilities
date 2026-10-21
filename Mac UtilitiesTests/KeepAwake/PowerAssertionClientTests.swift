import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Mac_Utilities

@Suite(.serialized)
@MainActor
struct PowerAssertionClientTests {
    @Test(arguments: [PowerAssertionKind.systemIdle, .displayIdle])
    func createsCorrectNamedAssertionsWithoutNativeTimeout(_ kind: PowerAssertionKind) throws {
        var receivedProperties: [[String: Any]] = []
        let client = PowerAssertionClient(
            createAssertion: { properties in
                receivedProperties.append(properties)
                return (kIOReturnSuccess, 41)
            },
            releaseAssertion: { _ in kIOReturnSuccess }
        )

        let id = try client.create(kind, timeout: nil)

        #expect(id == PowerAssertionID(rawValue: 41))
        #expect(receivedProperties.count == 1)
        let properties = try #require(receivedProperties.first)
        let expectedType = kind == .systemIdle
            ? kIOPMAssertionTypePreventUserIdleSystemSleep as String
            : kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        #expect(properties[kIOPMAssertionTypeKey as String] as? String == expectedType)
        #expect(properties[kIOPMAssertionNameKey as String] as? String == kind.assertionName)
        #expect(properties[kIOPMAssertionLevelKey as String] as? NSNumber == NSNumber(value: kIOPMAssertionLevelOn))
        #expect(properties[kIOPMAssertionTimeoutKey as String] == nil)
        #expect(properties[kIOPMAssertionTimeoutActionKey as String] == nil)
    }

    @Test(arguments: [PowerAssertionKind.systemIdle, .displayIdle])
    func finiteTimeoutUsesTurnOffAction(_ kind: PowerAssertionKind) throws {
        var receivedProperties: [[String: Any]] = []
        let client = PowerAssertionClient(
            createAssertion: { properties in
                receivedProperties.append(properties)
                return (kIOReturnSuccess, 7)
            },
            releaseAssertion: { _ in kIOReturnSuccess }
        )

        _ = try client.create(kind, timeout: 90)

        let properties = try #require(receivedProperties.first)
        #expect(properties[kIOPMAssertionTimeoutKey as String] as? NSNumber == NSNumber(value: 90))
        #expect(properties[kIOPMAssertionTimeoutActionKey as String] as? String == kIOPMAssertionTimeoutActionTurnOff as String)
    }

    @Test(arguments: [0, -1, .infinity, .nan])
    func rejectsInvalidTimeoutWithoutCallingNativeCreate(_ timeout: Double) {
        var createCalls = 0
        let client = PowerAssertionClient(
            createAssertion: { _ in
                createCalls += 1
                return (kIOReturnSuccess, 1)
            },
            releaseAssertion: { _ in kIOReturnSuccess }
        )

        #expect(throws: PowerAssertionError.invalidTimeout) {
            try client.create(.systemIdle, timeout: timeout)
        }
        #expect(createCalls == 0)
    }

    @Test
    func createFailureCarriesKindAndIOKitStatus() {
        let client = PowerAssertionClient(
            createAssertion: { _ in (kIOReturnNotPermitted, 0) },
            releaseAssertion: { _ in kIOReturnSuccess }
        )

        #expect(throws: PowerAssertionError.createFailed(kind: .displayIdle, status: kIOReturnNotPermitted)) {
            try client.create(.displayIdle, timeout: nil)
        }
    }

    @Test
    func releaseUsesOnlyTheSuppliedIDAndReportsFailure() {
        var releasedIDs: [UInt32] = []
        let client = PowerAssertionClient(
            createAssertion: { _ in (kIOReturnSuccess, 0) },
            releaseAssertion: { id in
                releasedIDs.append(id)
                return kIOReturnNotPermitted
            }
        )
        let id = PowerAssertionID(rawValue: 29)

        #expect(throws: PowerAssertionError.releaseFailed(id: id, status: kIOReturnNotPermitted)) {
            try client.release(id)
        }
        #expect(releasedIDs == [29])
    }
}
