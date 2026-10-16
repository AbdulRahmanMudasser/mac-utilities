import Foundation
import SystemConfiguration

enum NetworkInterfaceLabel {
    static func displayName(_ identifier: String?, names: [String: String]) -> String {
        guard let identifier, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Not Reported"
        }
        if let name = names[identifier], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "Network Interface (\(identifier))"
    }

    static func currentDisplayName(_ identifier: String?) -> String {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let identifier = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[identifier] = name
            }
        }
        return displayName(identifier, names: names)
    }
}
