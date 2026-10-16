import Foundation

nonisolated struct UsageStoragePaths: Sendable {
    let stateURL: URL
    let isVerification: Bool

    enum ConfigurationError: LocalizedError {
        case missingGroup, inaccessibleGroup, invalidNamespace, releaseNamespace

        var errorDescription: String? {
            switch self {
            case .missingGroup: "The Shared Usage Group Is Not Configured."
            case .inaccessibleGroup: "The Shared Usage Group Could Not Be Opened."
            case .invalidNamespace: "The Verification Namespace Is Invalid."
            case .releaseNamespace: "Verification Storage Is Not Allowed In A Release Build."
            }
        }
    }

    static func resolve(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
                        groupContainer: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }) throws -> UsageStoragePaths {
        guard let identifier = info["MacUtilitiesAppGroupIdentifier"] as? String,
              !identifier.isEmpty, !identifier.contains("$(") else { throw ConfigurationError.missingGroup }
        guard var root = groupContainer(identifier) else { throw ConfigurationError.inaccessibleGroup }
        let namespace = (info["MACUTILITIES_VERIFICATION_NAMESPACE"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !namespace.isEmpty {
            #if DEBUG
            guard let uuid = UUID(uuidString: namespace) else { throw ConfigurationError.invalidNamespace }
            root.appendPathComponent("Verification/" + uuid.uuidString, isDirectory: true)
            #else
            throw ConfigurationError.releaseNamespace
            #endif
        }
        let canonical = root.appendingPathComponent("Library/Application Support/MacUtilities/today-usage.json")
        return UsageStoragePaths(stateURL: canonical,
            isVerification: !namespace.isEmpty)
    }
}
