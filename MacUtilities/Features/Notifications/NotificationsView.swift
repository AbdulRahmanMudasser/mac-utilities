import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var controller: NotificationsController

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var statusActions: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            if controller.isRequestingAuthorization || controller.isDelivering {
                ProgressView()
                    .controlSize(UtilityStyle.progressControlSize)
                    .accessibilityLabel(controller.isRequestingAuthorization ? "Requesting Notification Permission" : "Sending Notification")
            }
            if let title = controller.permissionActionTitle {
                Button(title) { controller.setEnabled(true) }
                    .buttonStyle(.bordered)
                    .handPointer()
            }
            if controller.canRetryDelivery {
                Button("Retry Delivery") { controller.retryDelivery() }
                    .buttonStyle(.bordered)
                    .handPointer()
            }
            if controller.recoveryAction == .openSettings {
                Button("Open Settings") {
                    controller.openNotificationSettings()
                }
                .buttonStyle(.bordered)
                .handPointer()
                .accessibilityLabel("Open Notification Settings")
            }
        }
    }

    private var statusCard: some View {
        UtilityCapabilityCard(
            title: controller.statusText,
            isActive: controller.capabilityState == .authorized,
            action: AnyView(statusActions)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notification Capability")
        .accessibilityValue(
            [controller.statusText, controller.authorizationValue, controller.statusDetail]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private var enableNotificationsAction: AnyView {
        AnyView(
            Toggle("Enable Notifications", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable Notifications")
                .accessibilityValue(controller.isEnabled ? "On" : "Off")
                .handPointer()
        )
    }

    var body: some View {
        UtilityScrollContent {
            statusCard
            UtilityPanel(
                "Notifications",
                action: enableNotificationsAction,
                showsContent: false
            ) {
                EmptyView()
            }
            UtilityPanel(
                "Keep Awake Timer",
                description: "Shows a macOS notification when a timed Keep Awake session ends.",
                showsContent: false
            ) {
                EmptyView()
            }
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .task { await controller.refreshAuthorization() }
    }
}
