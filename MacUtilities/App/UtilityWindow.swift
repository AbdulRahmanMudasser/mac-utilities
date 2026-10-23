import AppKit
import Combine
import SwiftUI

enum UtilitySection: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case keepAwake = "Keep Awake"
    case usage = "Usage"
    case notifications = "Notifications"
    case settings = "Settings"

    var id: Self { self }
    var shortcut: KeyEquivalent {
        switch self {
        case .connection: "1"
        case .keepAwake: "2"
        case .usage: "3"
        case .notifications: "4"
        case .settings: "5"
        }
    }
}

struct MenuBarPopoverWindowAccessor: NSViewRepresentable {
    let coordinator: UtilityWindowCoordinator

    func makeNSView(context: Context) -> PopoverWindowView {
        let view = PopoverWindowView(frame: .zero)
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: PopoverWindowView, context: Context) {
        view.coordinator = coordinator
        if let window = view.window { coordinator.menuBarPopoverWindow = window }
    }

    final class PopoverWindowView: NSView {
        weak var coordinator: UtilityWindowCoordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.menuBarPopoverWindow = window }
        }
    }
}

@MainActor
final class UtilityWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let minimumContentSize = UtilityStyle.Window.minimumSize
    @Published var selection: UtilitySection = .connection {
        didSet { updateWiFiVisibility() }
    }
    @Published private(set) var usageRequest: UsagePresentationRequest?

    struct UsagePresentationRequest: Equatable {
        let range: UsageHistoryRange
        let generation: UUID
    }

    func consumeUsageRequest(_ generation: UUID) {
        if usageRequest?.generation == generation { usageRequest = nil }
    }

    func presentUsage(range: UsageHistoryRange) {
        guard !hasShutDown else { return }
        usageRequest = UsagePresentationRequest(range: range, generation: UUID())
        present(.usage)
    }

    var isKeepAwakeSurfaceDisplayable: Bool {
        guard selection == .keepAwake, let window else { return false }
        return NSApp.isActive && !isApplicationHidden() && isWindowDisplayable(window)
    }

    weak var menuBarPopoverWindow: NSWindow?
    private(set) var window: NSWindow?
    private let diagnostics: ConnectionDiagnostics
    private let wifiQualityMonitor: WiFiQualityMonitor?
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let activateApplication: @MainActor () -> Void
    private let isApplicationHidden: @MainActor () -> Bool
    private let isWindowDisplayable: @MainActor (NSWindow) -> Bool
    private let content: (UtilityWindowCoordinator) -> AnyView
    private var wakeObserver: NSObjectProtocol?
    private var hasShutDown = false

    init(diagnostics: ConnectionDiagnostics,
         wifiQualityMonitor: WiFiQualityMonitor? = nil,
         setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
         activateApplication: @escaping @MainActor () -> Void = { NSApp.activate() },
         isApplicationHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden },
         isWindowDisplayable: @escaping @MainActor (NSWindow) -> Bool = { window in
             window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
         },
         content: @escaping (UtilityWindowCoordinator) -> AnyView) {
        self.diagnostics = diagnostics
        self.wifiQualityMonitor = wifiQualityMonitor
        self.setActivationPolicy = setActivationPolicy
        self.activateApplication = activateApplication
        self.isApplicationHidden = isApplicationHidden
        self.isWindowDisplayable = isWindowDisplayable
        self.content = content
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationVisibilityDidChange(_:)),
            name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationVisibilityDidChange(_:)),
            name: NSApplication.didUnhideNotification, object: nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.deliverWorkspaceWake()
        }
    }

    func present(_ section: UtilitySection) {
        menuBarPopoverWindow?.orderOut(nil)
        selection = section
        let target: NSWindow
        if let window {
            target = window
        } else {
            target = NSWindow(contentRect: NSRect(origin: .zero, size: UtilityStyle.Window.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            target.title = "Mac Utilities"
            target.identifier = NSUserInterfaceItemIdentifier("utility-window")
            target.isReleasedWhenClosed = false
            target.tabbingMode = .disallowed
            target.delegate = self
            target.center()
            window = target
            observeVisibility(for: target)
        }
        if target.contentViewController == nil {
            let frame = target.frame
            let host = NSHostingController(rootView: content(self))
            host.sizingOptions = []
            let container = NSViewController()
            container.view = NSView(frame: NSRect(origin: .zero, size: target.contentRect(forFrameRect: frame).size))
            container.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            ])
            target.contentViewController = container
            target.contentMinSize = Self.minimumContentSize
            target.setFrame(frame, display: false)
        }
        synchronizeContentFrame(target)
        #if DEBUG
        if CommandLine.arguments.contains("--stability-preview") || CommandLine.arguments.contains(where: { $0.hasPrefix("--stability-preview=") }) {
            target.appearance = NSAppearance(named: CommandLine.arguments.contains("--stability-preview-light") ? .aqua : .darkAqua)
            if CommandLine.arguments.contains("--stability-preview-compact") {
                target.setContentSize(Self.minimumContentSize)
            } else if CommandLine.arguments.contains("--stability-preview-expanded") {
                target.setContentSize(NSSize(width: 1100, height: 800))
            }
        }
        if (CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains(where: { $0.hasPrefix("--usage-preview=") })) && CommandLine.arguments.contains("--usage-preview-light") {
            target.appearance = NSAppearance(named: .aqua)
        }
        if (CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains(where: { $0.hasPrefix("--usage-preview=") })) && CommandLine.arguments.contains("--usage-preview-compact") {
            target.setContentSize(Self.minimumContentSize)
        } else if (CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains(where: { $0.hasPrefix("--usage-preview=") })) && CommandLine.arguments.contains("--usage-preview-expanded") {
            target.setContentSize(NSSize(width: 1100, height: 800))
        }
        if CommandLine.arguments.contains("--keep-awake-preview") || CommandLine.arguments.contains(where: { $0.hasPrefix("--keep-awake-preview=") }) {
            target.appearance = NSAppearance(named: CommandLine.arguments.contains("--keep-awake-preview-light") ? .aqua : .darkAqua)
            if CommandLine.arguments.contains("--keep-awake-preview-compact") {
                target.setContentSize(Self.minimumContentSize)
            } else if CommandLine.arguments.contains("--keep-awake-preview-expanded") {
                target.setContentSize(NSSize(width: 1100, height: 800))
            }
        }
        let hasNotificationPreview = CommandLine.arguments.contains("--notification-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--notification-preview=") })
        if hasNotificationPreview {
            target.appearance = NSAppearance(named: CommandLine.arguments.contains("--notification-preview-light") ? .aqua : .darkAqua)
            if CommandLine.arguments.contains("--notification-preview-compact") {
                target.setContentSize(Self.minimumContentSize)
            } else if CommandLine.arguments.contains("--notification-preview-expanded") {
                target.setContentSize(NSSize(width: 1100, height: 800))
            }
        }
        let hasSettingsPreview = CommandLine.arguments.contains("--settings-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--settings-preview=") })
        if hasSettingsPreview {
            target.appearance = NSAppearance(named: CommandLine.arguments.contains("--settings-preview-light") ? .aqua : .darkAqua)
            if CommandLine.arguments.contains("--settings-preview-compact") {
                target.setContentSize(Self.minimumContentSize)
            } else if CommandLine.arguments.contains("--settings-preview-expanded") {
                target.setContentSize(NSSize(width: 1100, height: 800))
            }
        }
        #endif
        setActivationPolicy(.regular)
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
        activateApplication()
        updateWiFiVisibility()
    }

    func windowDidResize(_ notification: Notification) {
        guard let target = notification.object as? NSWindow, target === window else { return }
        synchronizeContentFrame(target)
    }

    private func synchronizeContentFrame(_ target: NSWindow) {
        let size = target.contentRect(forFrameRect: target.frame).size
        target.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        diagnostics.cancel()
        wifiQualityMonitor?.setVisible(false)
        // Rebuild transient view state on reopen; measurement results remain in the controller.
        closing.contentViewController = nil
        setActivationPolicy(.accessory)
    }

    @objc private func applicationVisibilityDidChange(_ notification: Notification) {
        guard let application = notification.object as? NSApplication, application === NSApp else { return }
        updateWiFiVisibility()
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        updateWiFiVisibility()
    }

    private func observeVisibility(for target: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)), name: name, object: target)
        }
    }

    private func updateWiFiVisibility() {
        wifiQualityMonitor?.setVisible(isConnectionSurfaceVisible)
    }

    private var isConnectionSurfaceVisible: Bool {
        guard !hasShutDown, selection == .connection, let window else { return false }
        return !isApplicationHidden() && isWindowDisplayable(window)
    }

    private nonisolated func deliverWorkspaceWake() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { refreshAfterWake() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { refreshAfterWake() }
            }
        }
    }

    private func refreshAfterWake() {
        guard !hasShutDown else { return }
        wifiQualityMonitor?.refreshAfterWake(isVisible: isConnectionSurfaceVisible)
    }

    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        wifiQualityMonitor?.shutdown()
        NotificationCenter.default.removeObserver(self)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        diagnostics.shutdown()
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
        setActivationPolicy(.accessory)
    }
}

struct UtilityWindowView: View {
    @EnvironmentObject private var utilityWindow: UtilityWindowCoordinator
    @EnvironmentObject private var diagnostics: ConnectionDiagnostics

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: UtilityStyle.sidebarSpacing) {
                ForEach(UtilitySection.allCases) { section in
                    Button {
                        utilityWindow.selection = section
                    } label: {
                        HStack(spacing: UtilityStyle.contentSpacing) {
                            Text(section.rawValue)
                            Spacer(minLength: 0)
                            if section == .connection && diagnostics.isRunning {
                                ProgressView().controlSize(UtilityStyle.sidebarProgressControlSize)
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(UtilityStyle.sidebarFont(selected: utilityWindow.selection == section))
                        .padding(.horizontal, UtilityStyle.contentSpacing)
                        .padding(.vertical, UtilityStyle.sidebarVerticalPadding)
                        .background(utilityWindow.selection == section ? UtilityStyle.sidebarSelectedBackground : .clear,
                                    in: RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handPointer()
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(section.rawValue)
                    .accessibilityValue(section == .connection && diagnostics.isRunning ? "Check Running" : "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(utilityWindow.selection == section ? .isSelected : [])
                }
                Spacer()
            }
            .padding(UtilityStyle.contentSpacing)
            .frame(width: UtilityStyle.sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(UtilityStyle.sidebarBackground)
            Divider()
            Group {
                switch utilityWindow.selection {
                case .connection: ConnectionCheckView()
                case .keepAwake: KeepAwakeView()
                case .usage: UsageHistoryView()
                case .notifications: NotificationsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}
