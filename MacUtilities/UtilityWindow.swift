import AppKit
import Combine
import SwiftUI

enum UtilitySection: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case settings = "Settings"

    var id: Self { self }
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
    @Published var selection: UtilitySection = .connection
    weak var menuBarPopoverWindow: NSWindow?
    private(set) var window: NSWindow?
    private let diagnostics: ConnectionDiagnostics
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activateApplication: () -> Void
    private let content: (UtilityWindowCoordinator) -> AnyView

    init(diagnostics: ConnectionDiagnostics,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
         activateApplication: @escaping () -> Void = { NSApp.activate() },
         content: @escaping (UtilityWindowCoordinator) -> AnyView) {
        self.diagnostics = diagnostics
        self.setActivationPolicy = setActivationPolicy
        self.activateApplication = activateApplication
        self.content = content
        super.init()
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
        setActivationPolicy(.regular)
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
        activateApplication()
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
        // Rebuild transient view state on reopen; measurement results remain in the controller.
        closing.contentViewController = nil
        setActivationPolicy(.accessory)
    }

    func shutdown() {
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
                    .keyboardShortcut(section == .connection ? "1" : "2", modifiers: .command)
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
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}
