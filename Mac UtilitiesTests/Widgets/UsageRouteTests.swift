import Foundation
import Testing
@testable import Mac_Utilities

struct UsageRouteTests {
    @Test func allRangesRoundTrip() {
        for range in UsageHistoryRange.allCases {
            #expect(UsageRoute(url: UsageRoute.url(for: range))?.range == range)
        }
    }

    @Test func unknownRangeUsesDefaultAndOtherActionsAreRejected() throws {
        for value in ["macutilities://usage", "macutilities://usage?range=unknown"] {
            #expect(UsageRoute(url: try #require(URL(string: value)))?.range == .thisMonth)
        }
        for value in ["https://usage", "macutilities://reset", "macutilities://usage/file", "macutilities://usage?file=x", "macutilities://usage?range=sevenDays&range=thisMonth", "macutilities://user@usage", "macutilities://usage#reset"] {
            #expect(UsageRoute(url: try #require(URL(string: value))) == nil)
        }
    }
}
