import AppKit
import SwiftUI

struct HostStartupView: View {
    @ObservedObject var controller: HostStartupController

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            UtilityCapabilityCard(title: title, isActive: false, detail: detail,
                action: AnyView(HStack {
                    if controller.state == .migrating {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { controller.cancel() }.handPointer()
                    }
                    if case .failed = controller.state {
                        Button("Retry") { controller.retry() }.handPointer()
                    }
                    Button("Quit") { NSApp.terminate(nil) }.handPointer()
                }))
        }
        .padding(20)
        .frame(width: 380)
    }

    private var title: String {
        switch controller.state {
        case .failed: "Saved Data Needs Attention"
        case .cancelled: "Startup Cancelled"
        default: "Preparing Saved Data"
        }
    }

    private var detail: String? {
        if case .failed(let message) = controller.state { return message }
        return controller.state == .cancelled ? "Quit and reopen Mac Utilities to try again." : nil
    }
}
