import AppKit
import SwiftUI
import Testing
@testable import Mac_Utilities

@MainActor
private final class PresentationPowerAssertions: PowerAsserting {
    private var nextID: UInt32 = 1

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID {
        defer { nextID &+= 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func release(_ id: PowerAssertionID) throws {}
}

@Suite(.serialized)
@MainActor
struct KeepAwakePresentationTests {
    @Test func menuBarCompositionPreservesRatesAndUsesNoSeparatorDot() {
        let rate = "↓ 1.2 MB/s ↑ 300 KB/s"
        #expect(MenuBarStatusLabel.displayedText(rateText: rate, keepAwakePrefix: "") == rate)
        #expect(MenuBarStatusLabel.displayedText(rateText: rate, keepAwakePrefix: "☾ 30 Min\u{2003}") == "☾ 30 Min\u{2003}\(rate)")
        #expect(MenuBarStatusLabel.displayedText(rateText: rate, keepAwakePrefix: "☾ ∞\u{2003}") == "☾ ∞\u{2003}\(rate)")
        #expect(!MenuBarStatusLabel.displayedText(rateText: rate, keepAwakePrefix: "☾ 30 Min\u{2003}").contains("·"))
    }

    @Test func enabledPresentationSupportsTwoThreeAndFourOrderedPresets() throws {
        let four = KeepAwakePresetConfiguration.defaults
        let three = try four.settingEnabled(false, for: .timedThree)
        let two = try three.settingEnabled(false, for: .untilStopped)

        #expect(four.enabledPresets.map(\.title) == ["30 Min", "1 Hour", "2 Hours", "Until Stopped"])
        #expect(three.enabledPresets.map(\.title) == ["30 Min", "1 Hour", "Until Stopped"])
        #expect(two.enabledPresets.map(\.title) == ["30 Min", "1 Hour"])
    }

    @Test func lastRanUsesSharedCheckmarkAndHonestOutcomeSummaries() {
        #expect(KeepAwakeView.lastRanSymbol == "checkmark.circle.fill")
        #expect(KeepAwakeView.lastRanColor == UtilityStyle.successColor)
        #expect(KeepAwakeSessionOutcome.completed.summary == "Completed")
        #expect(KeepAwakeSessionOutcome.cancelled(reason: .stopped).summary == "Cancelled")
        #expect(KeepAwakeSessionOutcome.cancelled(reason: .replaced).summary == "Cancelled · Replaced")
        #expect(KeepAwakeSessionOutcome.cancelled(reason: .applicationQuit).summary == "Cancelled · Mac Utilities Quit")
    }

    @Test func timestampRowsRenderValuesInsteadOfPlaceholderText() {
        let timestamp = Date(timeIntervalSince1970: 1_797_000_000)
        let rendered = UtilityTimestampRow.timestampText(for: timestamp, detail: "5 Min · Completed")

        #expect(rendered.contains("5 Min · Completed"))
        #expect(!rendered.contains("(timestamp)"))
        #expect(!rendered.contains("(detail)"))
    }

    @Test func realKeepAwakeViewKeepsSharedBoundsAcrossSupportedSizesAndAppearances() async throws {
        let suiteName = "MacUtilities.KeepAwakePresentationTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = KeepAwakeController(power: PresentationPowerAssertions(), preferences: preferences)
        defer { controller.shutdown() }
        let host = NSHostingView(rootView: KeepAwakeView().environmentObject(controller))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 440, height: 420), NSSize(width: 680, height: 660), NSSize(width: 920, height: 800)] {
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                #expect(host.bounds.size == size)
            }
        }
    }

}
