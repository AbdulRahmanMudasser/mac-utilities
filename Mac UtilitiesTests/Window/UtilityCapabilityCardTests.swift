import AppKit
import SwiftUI
import Testing
@testable import Mac_Utilities

@Suite(.serialized)
@MainActor
struct UtilityCapabilityCardTests {
    private func fittedSize(title: String, detail: String?, width: CGFloat,
                            appearance: NSAppearance.Name, action: AnyView? = nil) -> NSSize {
        let host = NSHostingView(rootView:
            UtilityCapabilityCard(message: UtilityCapabilityMessage(title: title, detail: detail),
                                  isActive: false, action: action)
                .font(UtilityStyle.bodyFont)
                .controlSize(UtilityStyle.controlSize)
                .frame(width: width)
        )
        host.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func explanatoryDetailsRemainVisibleAndWrapAtSupportedWidths() {
        let title = "Saved Usage Could Not Be Opened."
        let detail = "Another Mac Utilities instance already owns the usage history."
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var previousHeight = CGFloat.greatestFiniteMagnitude
            for width: CGFloat in [400, 640, 880] {
                let titleOnly = fittedSize(title: title, detail: nil, width: width, appearance: appearance)
                let explained = fittedSize(title: title, detail: detail, width: width, appearance: appearance)
                #expect(abs(explained.width - width) < 1)
                #expect(explained.height >= titleOnly.height + UtilityStyle.capabilityDetailSpacing + 10)
                #expect(explained.height <= previousHeight + 1)
                previousHeight = explained.height
            }
        }
    }

    @Test func narrowRecoveryCardAccommodatesBothActionsAndExplanation() {
        let actions = AnyView(HStack(spacing: UtilityStyle.contentSpacing) {
            Button("Retry Delivery") {}
            Button("Open Settings") {}
        }.buttonStyle(.bordered))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let wide = fittedSize(title: "Notification Delivery Failed",
                                 detail: "The last notification could not be delivered.",
                                 width: 880, appearance: appearance, action: actions)
            let narrow = fittedSize(title: "Notification Delivery Failed",
                                   detail: "The last notification could not be delivered.",
                                   width: 400, appearance: appearance, action: actions)
            #expect(abs(narrow.width - 400) < 1)
            #expect(narrow.height > wide.height)
        }
    }
}
