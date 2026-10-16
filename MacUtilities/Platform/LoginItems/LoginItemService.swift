import Foundation
import ServiceManagement

@MainActor
struct LoginItemService {
    private let enabled: () -> Bool
    private let update: (Bool) throws -> Void

    init(enabled: @escaping () -> Bool, update: @escaping (Bool) throws -> Void) {
        self.enabled = enabled
        self.update = update
    }

    var isEnabled: Bool { enabled() }

    func setEnabled(_ value: Bool) throws -> Bool {
        try update(value)
        return enabled()
    }

    static var system: LoginItemService {
        LoginItemService(enabled: { SMAppService.mainApp.status == .enabled }, update: { value in
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        })
    }

    static var isolated: LoginItemService {
        LoginItemService(enabled: { false }, update: { _ in throw CocoaError(.featureUnsupported) })
    }
}
