import AppKit
import SwiftUI
import Testing
@testable import Mac_Utilities

@MainActor
private final class UtilityWindowVisibilityState {
    var appHidden = false
    var displayable = true
}

@MainActor
private final class UtilityWindowPowerAssertions: PowerAsserting {
    private(set) var released: [PowerAssertionID] = []
    private var nextID: UInt32 = 1

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID {
        defer { nextID &+= 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func release(_ id: PowerAssertionID) throws {
        released.append(id)
    }
}

@Suite(.serialized)
@MainActor
struct UtilityWindowTests {
    @Test func queuedAndRepeatedUsageRoutesReuseWindow() throws {
        let diagnostics = ConnectionDiagnostics()
        let coordinator = UtilityWindowCoordinator(diagnostics: diagnostics,
            setActivationPolicy: { _ in }, activateApplication: {}) { _ in AnyView(Text("Fixture")) }
        defer { coordinator.shutdown() }
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [UsageRoute.url(for: .sevenDays)])
        #expect(coordinator.window == nil)
        delegate.utilityWindow = coordinator
        #expect(coordinator.window == nil)
        delegate.markWindowRoutingReady()
        let first = try #require(coordinator.window)
        #expect(coordinator.selection == .usage)
        #expect(coordinator.usageRequest?.range == .sevenDays)
        let generation = coordinator.usageRequest?.generation
        coordinator.selection = .connection
        first.miniaturize(nil)
        delegate.application(NSApp, open: [UsageRoute.url(for: .sevenDays)])
        #expect(coordinator.window === first)
        #expect(!first.isMiniaturized)
        #expect(coordinator.selection == .usage)
        #expect(coordinator.usageRequest?.generation != generation)
        #expect(!diagnostics.isRunning)
    }

    #if DEBUG
    @Test func realStabilityViewsKeepSharedBoundsAcrossSizesAppearancesAndEmptyStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stability-window-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("today-usage.json")
        try UsageStateStore.saveState(PersistedUsage(schemaVersion: 3,
            localDayKey: UsageHistory.key(for: Date()), history: []), at: file)
        let monitor = UsageMonitor(startAutomatically: false,
            storagePaths: UsageStoragePaths(stateURL: file, isVerification: true))
        let diagnostics = ConnectionDiagnostics()
        let wifiQualityMonitor = WiFiQualityMonitor(reader: ImmediateWiFiQualityReader([sampleWiFiSnapshot()]))
        let subject = UtilityWindowCoordinator(diagnostics: diagnostics, wifiQualityMonitor: wifiQualityMonitor,
            setActivationPolicy: { _ in }, activateApplication: {}) { coordinator in
            AnyView(UtilityWindowView().environmentObject(monitor).environmentObject(diagnostics)
                .environmentObject(wifiQualityMonitor).environmentObject(coordinator))
        }
        defer { subject.shutdown(); monitor.shutdown(); try? FileManager.default.removeItem(at: directory) }
        subject.present(.connection)
        for mode in 0..<3 {
            diagnostics.showStabilityPreview(unobserved: mode == 1, sparse: mode == 2)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                subject.window?.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 620, height: 420), NSSize(width: 860, height: 660), NSSize(width: 1100, height: 800)] {
                    subject.window?.setContentSize(size)
                    let view = try #require(subject.window?.contentView)
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    view.displayIfNeeded()
                    #expect(view.bounds.size == size)
                    #expect(subject.window?.contentViewController?.children.first?.view.bounds.size == size)
                }
            }
        }
        #expect(!monitor.isMonitoringActive)
        #expect(!diagnostics.isRunning)
    }
    #endif

    private func coordinator(_ diagnostics: ConnectionDiagnostics? = nil) -> UtilityWindowCoordinator {
        UtilityWindowCoordinator(diagnostics: diagnostics ?? ConnectionDiagnostics(),
                                 setActivationPolicy: { _ in }, activateApplication: {}) { _ in
            AnyView(Text("Window Test"))
        }
    }

    @Test func wifiSamplingFollowsConnectionSurfaceVisibilityAndWake() async {
        let reader = ImmediateWiFiQualityReader([sampleWiFiSnapshot(), sampleWiFiSnapshot(signal: -53)])
        let wifiQualityMonitor = WiFiQualityMonitor(reader: reader, refreshInterval: .seconds(30))
        let visibility = UtilityWindowVisibilityState()
        let subject = UtilityWindowCoordinator(
            diagnostics: ConnectionDiagnostics(), wifiQualityMonitor: wifiQualityMonitor,
            setActivationPolicy: { _ in }, activateApplication: {},
            isApplicationHidden: { visibility.appHidden }, isWindowDisplayable: { _ in visibility.displayable }
        ) { _ in AnyView(Text("Window Test")) }
        let unrelated = NSWindow()
        defer { subject.shutdown(); unrelated.orderOut(nil) }

        subject.present(.connection)
        await waitForWiFiReads(1, from: reader)
        #expect(wifiQualityMonitor.isVisible)

        subject.selection = .usage
        #expect(!wifiQualityMonitor.isVisible)
        subject.selection = .connection
        #expect(wifiQualityMonitor.isVisible)

        visibility.appHidden = true
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        #expect(!wifiQualityMonitor.isVisible)
        visibility.appHidden = false
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        #expect(wifiQualityMonitor.isVisible)

        visibility.displayable = false
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: subject.window)
        #expect(!wifiQualityMonitor.isVisible)
        visibility.displayable = true
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: subject.window)
        #expect(wifiQualityMonitor.isVisible)

        visibility.displayable = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: subject.window)
        #expect(!wifiQualityMonitor.isVisible)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: unrelated)
        #expect(!wifiQualityMonitor.isVisible)
        visibility.displayable = true
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: subject.window)
        #expect(wifiQualityMonitor.isVisible)

        let readsBeforeWake = await reader.readCount()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitForWiFiReads(readsBeforeWake + 1, from: reader)
        for _ in 0..<2_000 where wifiQualityMonitor.snapshot?.sampledAt != Date(timeIntervalSince1970: 1_797_000_000) {
            await Task.yield()
        }
        #expect(wifiQualityMonitor.snapshot?.sampledAt == Date(timeIntervalSince1970: 1_797_000_000))

        subject.window?.close()
        #expect(!wifiQualityMonitor.isVisible)
        subject.shutdown()
        #expect(wifiQualityMonitor.snapshot == nil)
    }

    @Test func windowCloseRejectsAnInFlightWiFiSnapshot() async {
        let reader = DeferredWiFiQualityReader()
        let wifiQualityMonitor = WiFiQualityMonitor(reader: reader, refreshInterval: .seconds(30))
        let subject = UtilityWindowCoordinator(
            diagnostics: ConnectionDiagnostics(), wifiQualityMonitor: wifiQualityMonitor,
            setActivationPolicy: { _ in }, activateApplication: {}, isApplicationHidden: { false },
            isWindowDisplayable: { _ in true }
        ) { _ in AnyView(Text("Window Test")) }
        defer { subject.shutdown() }

        subject.present(.connection)
        await waitForWiFiReads(1, from: reader)
        subject.window?.close()
        #expect(!wifiQualityMonitor.isVisible)
        await reader.resolveNext(with: sampleWiFiSnapshot(signal: -39))
        for _ in 0..<2_000 { await Task.yield() }
        #expect(wifiQualityMonitor.snapshot == nil)
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
        #expect(UtilitySection.allCases == [.connection, .keepAwake, .usage, .settings])
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
        for section in [UtilitySection.connection, .keepAwake, .usage, .settings, .connection] {
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
        #expect(diagnostics.message == "Check Cancelled")
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

    @Test func stabilityNavigationKeepsSamplingAndCloseReopenRetainsPartialResults() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in stabilityReplyOutput() },
            stabilityClock: clock.makeClock(), stabilityEvents: { events })
        let initialWiFiSnapshot = sampleWiFiSnapshot()
        let wifiReader = ImmediateWiFiQualityReader([initialWiFiSnapshot, sampleWiFiSnapshot(signal: -56)])
        let wifiQualityMonitor = WiFiQualityMonitor(reader: wifiReader, refreshInterval: .seconds(30))
        let subject = UtilityWindowCoordinator(diagnostics: diagnostics, wifiQualityMonitor: wifiQualityMonitor,
            setActivationPolicy: { _ in }, activateApplication: {}, isApplicationHidden: { false },
            isWindowDisplayable: { _ in true }) { _ in AnyView(Text("Window Test")) }
        defer { subject.shutdown(); wifiQualityMonitor.shutdown() }

        subject.present(.connection)
        await waitForWiFiReads(1, from: wifiReader)
        await waitForWiFiSnapshot(initialWiFiSnapshot, from: wifiQualityMonitor)
        diagnostics.startStability()
        for _ in 0..<10_000 where (diagnostics.stabilitySnapshot?.observations.count ?? 0) < 2 {
            await Task.yield()
        }
        let initialID = diagnostics.stabilitySnapshot?.id
        #expect(initialID != nil)
        #expect(diagnostics.activity == .stability)
        #expect(wifiQualityMonitor.isVisible)

        subject.present(.usage)
        subject.present(.settings)
        #expect(diagnostics.activity == .stability)
        #expect(!wifiQualityMonitor.isVisible)
        #expect(diagnostics.stabilitySnapshot?.id == initialID)

        let originalWindow = subject.window
        originalWindow?.close()
        await diagnostics.waitUntilStopped()
        #expect(diagnostics.stabilitySnapshot?.status == .cancelled)
        #expect(diagnostics.stabilitySnapshot?.observations.count == 2)

        subject.present(.connection)
        await waitForWiFiReads(2, from: wifiReader)
        #expect(subject.window === originalWindow)
        #expect(subject.selection == .connection)
        #expect(subject.window?.isVisible == true)
        #expect(wifiQualityMonitor.isVisible)
        #expect(diagnostics.stabilitySnapshot?.id == initialID)
        #expect(diagnostics.stabilitySnapshot?.observations.count == 2)
        #expect(events.stopCount == 1)
    }

    @Test func stabilityShutdownCancelsAndRetainsTheCurrentSnapshot() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in stabilityReplyOutput() },
            stabilityClock: clock.makeClock(), stabilityEvents: { events })
        let subject = coordinator(diagnostics)
        subject.present(.connection)
        diagnostics.startStability()
        for _ in 0..<10_000 where (diagnostics.stabilitySnapshot?.observations.count ?? 0) < 2 {
            await Task.yield()
        }
        let initialID = diagnostics.stabilitySnapshot?.id

        subject.shutdown()
        await diagnostics.waitUntilStopped()

        #expect(subject.window == nil)
        #expect(!diagnostics.isRunning)
        #expect(diagnostics.stabilitySnapshot?.id == initialID)
        #expect(diagnostics.stabilitySnapshot?.status == .cancelled)
        #expect(diagnostics.stabilitySnapshot?.observations.count == 2)
        #expect(events.stopCount == 1)
    }

    @Test func applicationTerminationWaitsForStabilityCleanupBeforeReplying() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let diagnostics = ConnectionDiagnostics(processOperation: { _, _, _ in stabilityReplyOutput() },
            stabilityClock: clock.makeClock(), stabilityEvents: { events })
        diagnostics.startStability()
        for _ in 0..<10_000 where (diagnostics.stabilitySnapshot?.observations.count ?? 0) < 2 {
            await Task.yield()
        }

        let wifiSnapshot = sampleWiFiSnapshot()
        let wifiReader = ImmediateWiFiQualityReader([wifiSnapshot])
        let wifiQualityMonitor = WiFiQualityMonitor(reader: wifiReader, refreshInterval: .seconds(30))
        wifiQualityMonitor.setVisible(true)
        await waitForWiFiReads(1, from: wifiReader)
        await waitForWiFiSnapshot(wifiSnapshot, from: wifiQualityMonitor)

        let delegate = AppDelegate()
        delegate.diagnostics = diagnostics
        delegate.wifiQualityMonitor = wifiQualityMonitor
        let power = UtilityWindowPowerAssertions()
        let preferenceSuite = "MacUtilities.UtilityWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferenceSuite)!
        defer { preferences.removePersistentDomain(forName: preferenceSuite) }
        let keepAwake = KeepAwakeController(power: power, preferences: preferences)
        keepAwake.setActive(true)
        delegate.keepAwakeController = keepAwake
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(!keepAwake.isActive)
        #expect(power.released.map(\.rawValue) == [1])
        #expect(!wifiQualityMonitor.isVisible)
        #expect(wifiQualityMonitor.snapshot == nil)
        #expect(replies.isEmpty)
        #expect(diagnostics.isStopping)

        await diagnostics.waitUntilStopped()
        for _ in 0..<10_000 where replies.isEmpty { await Task.yield() }

        #expect(replies == [true])
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(power.released.map(\.rawValue) == [1])
        wifiQualityMonitor.shutdown()
        #expect(diagnostics.stabilitySnapshot?.status == .cancelled)
        #expect(events.stopCount == 1)
    }

    @Test func immediateTerminationReleasesKeepAwakeBeforeReturningAndWillTerminateIsIdempotent() {
        let power = UtilityWindowPowerAssertions()
        let preferenceSuite = "MacUtilities.UtilityWindowTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferenceSuite)!
        defer { preferences.removePersistentDomain(forName: preferenceSuite) }
        let keepAwake = KeepAwakeController(power: power, preferences: preferences)
        keepAwake.setKeepDisplayOn(true)
        keepAwake.setActive(true)
        let delegate = AppDelegate()
        delegate.keepAwakeController = keepAwake
        let diagnostics = ConnectionDiagnostics()
        delegate.diagnostics = diagnostics

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(!keepAwake.isActive)
        #expect(power.released.map(\.rawValue) == [2, 1])

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(power.released.map(\.rawValue) == [2, 1])
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

    @Test func utilitySectionsUseSequentialKeyboardShortcuts() {
        #expect(UtilitySection.connection.shortcut == "1")
        #expect(UtilitySection.keepAwake.shortcut == "2")
        #expect(UtilitySection.usage.shortcut == "3")
        #expect(UtilitySection.settings.shortcut == "4")
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
        try UsageStateStore.saveState(PersistedUsage(schemaVersion: 3, localDayKey: UsageHistory.key(for: date), history: records), at: url)
        let monitor = UsageMonitor(stateURL: url, startAutomatically: false, now: { date },
                                   calendar: { calendar }, readCounters: { [:] })
        let diagnostics = ConnectionDiagnostics()
        let wifiQualityMonitor = WiFiQualityMonitor(reader: ImmediateWiFiQualityReader([sampleWiFiSnapshot()]))
        let subject = UtilityWindowCoordinator(diagnostics: diagnostics, wifiQualityMonitor: wifiQualityMonitor,
            setActivationPolicy: { _ in }, activateApplication: {}) { coordinator in
            AnyView(UtilityWindowView().environmentObject(monitor).environmentObject(diagnostics)
                .environmentObject(wifiQualityMonitor).environmentObject(coordinator))
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
