import AppKit
import SwiftUI
import Testing
@testable import Mac_Utilities

@Suite(.serialized)
@MainActor
struct UtilityWindowTests {
    private func coordinator(_ diagnostics: ConnectionDiagnostics? = nil) -> UtilityWindowCoordinator {
        UtilityWindowCoordinator(diagnostics: diagnostics ?? ConnectionDiagnostics(),
                                 setActivationPolicy: { _ in }, activateApplication: {}) { _ in
            AnyView(Text("Window Test"))
        }
    }

    @Test func activationRequestsRestoreAccessoryModeWithoutChangingTestHostPolicy() {
        let originalPolicy = NSApp.activationPolicy()
        var policies: [NSApplication.ActivationPolicy] = []
        var activationCount = 0
        let subject = UtilityWindowCoordinator(diagnostics: ConnectionDiagnostics(),
            setActivationPolicy: { policies.append($0) },
            activateApplication: { activationCount += 1 }) { _ in AnyView(Text("Window Test")) }
        subject.present(.settings)
        subject.window?.close()
        subject.present(.connection)
        subject.shutdown()
        #expect(policies == [.regular, .accessory, .regular, .accessory])
        #expect(activationCount == 2)
        #expect(NSApp.activationPolicy() == originalPolicy)
    }

    @Test func startupDoesNotCreateAWindow() {
        let subject = coordinator()
        #expect(subject.window == nil)
        #expect(UtilitySection.allCases == [.connection, .usage, .settings])
    }

    @Test(arguments: UtilitySection.allCases)
    func presentingUtilityDismissesOnlyItsPopover(_ section: UtilitySection) {
        let subject = coordinator()
        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        defer {
            subject.shutdown()
            popover.orderOut(nil)
            unrelated.orderOut(nil)
        }
        subject.menuBarPopoverWindow = popover
        unrelated.orderFront(nil)
        for _ in 0..<2 {
            popover.orderFront(nil)
            #expect(popover.isVisible)
            subject.present(section)
            #expect(!popover.isVisible)
            #expect(unrelated.isVisible)
            #expect(subject.window?.isVisible == true)
            #expect(subject.selection == section)
        }
    }

    @Test func popoverViewRegistersItsEnclosingWindow() {
        let subject = coordinator()
        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        let view = MenuBarPopoverWindowAccessor.PopoverWindowView(frame: .zero)
        view.coordinator = subject
        popover.contentView = view
        #expect(subject.menuBarPopoverWindow === popover)
        subject.shutdown()
    }

    @Test(arguments: UtilitySection.allCases)
    func firstRequestSelectsRequestedSection(_ section: UtilitySection) {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(section)
        #expect(subject.selection == section)
        #expect(subject.window?.isVisible == true)
        #expect(subject.window?.title == "Mac Utilities")
        #expect(subject.window?.identifier?.rawValue == "utility-window")
    }

    @Test func repeatedRequestsReuseTheSameWindow() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        let original = subject.window
        for section in [UtilitySection.connection, .usage, .settings, .connection] {
            subject.present(section)
            #expect(subject.window === original)
            #expect(subject.selection == section)
        }
    }

    @Test func closeClearsTransientViewsAndReopenReusesWindow() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        let original = subject.window
        original?.close()
        #expect(original?.isVisible == false)
        #expect(original?.contentViewController == nil)
        subject.present(.connection)
        #expect(subject.window === original)
        #expect(subject.window?.contentViewController != nil)
        #expect(subject.window?.isVisible == true)
        #expect(subject.selection == .connection)
    }

    @Test func existingWindowIsUnminimizedAndBroughtForward() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        subject.window?.miniaturize(nil)
        subject.present(.connection)
        #expect(subject.window?.isMiniaturized == false)
        #expect(subject.window?.isVisible == true)
        #expect(subject.selection == .connection)
    }

    @Test func navigationDoesNotCancelButCloseDoes() async {
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        let subject = coordinator(diagnostics)
        defer { subject.shutdown() }
        subject.present(.connection)
        diagnostics.startLatency()
        #expect(diagnostics.isRunning)
        subject.present(.usage)
        #expect(diagnostics.isRunning)
        subject.present(.settings)
        #expect(diagnostics.isRunning)
        subject.window?.close()
        for _ in 0..<100 where diagnostics.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!diagnostics.isRunning)
        #expect(diagnostics.message == "Check Cancelled.")
    }

    @Test func shutdownReleasesWindowAndStopsWork() async {
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        let subject = coordinator(diagnostics)
        subject.present(.connection)
        diagnostics.startLatency()
        subject.shutdown()
        #expect(subject.window == nil)
        for _ in 0..<100 where diagnostics.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!diagnostics.isRunning)
    }

    @Test func resultsSurviveNavigationAndWindowReopen() async {
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in
            DiagnosticProcessOutput(stdout: Data("10 packets transmitted, 0 packets received, 100.0% packet loss".utf8), stderr: Data(), exitCode: 2)
        }, httpsOperation: { _ in
            HTTPSResult(elapsedMilliseconds: 12, statusCode: 200)
        })
        let subject = coordinator(diagnostics)
        defer { subject.shutdown() }
        subject.present(.connection)
        diagnostics.startLatency()
        for _ in 0..<100 where diagnostics.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(diagnostics.probes.count == 2)
        let completedAt = diagnostics.latencyCompletedAt
        #expect(completedAt != nil)
        subject.present(.usage)
        #expect(diagnostics.latencyCompletedAt == completedAt)
        subject.present(.settings)
        subject.window?.close()
        subject.present(.connection)
        #expect(diagnostics.probes.count == 2)
        #expect(diagnostics.probes.allSatisfy { $0.https?.statusCode == 200 })
        #expect(diagnostics.latencyCompletedAt == completedAt)
    }

    @Test func unrelatedWindowCloseDoesNotChangeUtilityState() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        let original = subject.window?.contentViewController
        let unrelated = NSWindow()
        subject.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: unrelated))
        #expect(subject.window?.contentViewController === original)
        #expect(subject.window?.isVisible == true)
    }

    @Test func hostingDoesNotShrinkWindowAcrossCloseAndReopen() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        subject.window?.setContentSize(NSSize(width: 940, height: 720))
        let size = subject.window?.frame.size
        subject.window?.close()
        subject.present(.connection)
        #expect(subject.window?.frame.size == size)
        #expect(subject.window?.contentMinSize == UtilityWindowCoordinator.minimumContentSize)
        let host = subject.window?.contentViewController?.children.first as? NSHostingController<AnyView>
        #expect(host?.sizingOptions == [])
        subject.present(.settings)
        #expect(subject.window?.frame.size == size)
    }

    @Test func applicationReopenRestoresExistingSectionWithoutCreatingASecondWindow() {
        let subject = coordinator()
        defer { subject.shutdown() }
        let delegate = AppDelegate()
        delegate.utilityWindow = subject
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(subject.window == nil)
        subject.present(.settings)
        let original = subject.window
        subject.window?.close()
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(subject.window === original)
        #expect(subject.selection == .settings)
        #expect(subject.window?.isVisible == true)
    }

    @Test func compactAndExpandedSizesSurviveNavigationAndReopen() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        for size in [NSSize(width: 620, height: 420), NSSize(width: 760, height: 500), NSSize(width: 1100, height: 800)] {
            subject.window?.setContentSize(size)
            subject.window?.layoutIfNeeded()
            subject.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(subject.window?.contentView?.bounds.size == size)
            #expect(subject.window?.contentViewController?.children.first?.view.bounds.size == size)
            subject.present(.connection)
            #expect(subject.window?.contentView?.bounds.size == size)
            subject.window?.close()
            subject.present(.settings)
            subject.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(subject.window?.contentView?.bounds.size == size)
            #expect(subject.window?.contentViewController?.children.first?.view.bounds.size == size)
        }
    }

    @Test func hostingConstraintsStayBoundedAndControllersReleaseOnClose() {
        let subject = coordinator()
        defer { subject.shutdown() }
        for _ in 0..<3 {
            weak var container: NSViewController?
            weak var host: NSViewController?
            autoreleasepool {
                subject.present(.connection)
                container = subject.window?.contentViewController
                host = container?.children.first
                #expect(container?.children.count == 1)
                #expect(container?.view.constraints.count == 4)
                #expect(container?.view.constraints.allSatisfy { $0.isActive && $0.constant == 0 } == true)
                #expect(host?.view.translatesAutoresizingMaskIntoConstraints == false)
                subject.window?.close()
            }
            #expect(container == nil)
            #expect(host == nil)
        }
    }

    @Test func unrelatedResizeNotificationDoesNotChangeUtilityFrame() {
        let subject = coordinator()
        defer { subject.shutdown() }
        subject.present(.settings)
        let original = subject.window?.contentView?.frame
        let unrelated = NSWindow()
        subject.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: unrelated))
        #expect(subject.window?.contentView?.frame == original)
    }

    @Test func usageKeepsExistingKeyboardShortcuts() {
        #expect(UtilitySection.connection.shortcut == "1")
        #expect(UtilitySection.settings.shortcut == "2")
        #expect(UtilitySection.usage.shortcut == "3")
    }

    @Test func realUsageViewKeepsSharedBoundsInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-window-fixture")
        let url = directory.appendingPathComponent("today-usage.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = UsageHistory.calendar()
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
        let records = (0..<30).compactMap { offset -> DailyUsageRecord? in
            guard offset != 6, let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            return DailyUsageRecord(dayKey: UsageHistory.key(for: day),
                downloaded: UInt64(offset == 8 ? 0 : 2 + offset % 14) * 1_000_000_000,
                uploaded: UInt64(offset == 8 ? 0 : 1 + offset % 3) * 500_000_000,
                firstObservedAt: day, lastObservedAt: day, isIncomplete: true)
        }
        try UsageMonitor.saveState(PersistedUsage(schemaVersion: 3, localDayKey: UsageHistory.key(for: date), history: records), at: url)
        let monitor = UsageMonitor(stateURL: url, startAutomatically: false, now: { date },
                                   calendar: { calendar }, readCounters: { [:] })
        let diagnostics = ConnectionDiagnostics()
        let subject = UtilityWindowCoordinator(diagnostics: diagnostics,
            setActivationPolicy: { _ in }, activateApplication: {}) { coordinator in
            AnyView(UtilityWindowView().environmentObject(monitor).environmentObject(diagnostics).environmentObject(coordinator))
        }
        defer { subject.shutdown(); try? FileManager.default.removeItem(at: directory) }
        subject.present(.usage)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            subject.window?.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 620, height: 420), NSSize(width: 860, height: 660), NSSize(width: 1100, height: 800)] {
                subject.window?.setContentSize(size)
                let view = try #require(subject.window?.contentView)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                view.displayIfNeeded()
                #expect(view.bounds.size == size)
                #expect(subject.window?.contentViewController?.children.first?.view.bounds.size == size)
            }
        }
    }
}
