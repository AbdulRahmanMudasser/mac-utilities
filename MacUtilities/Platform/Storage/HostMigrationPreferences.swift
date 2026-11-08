import CoreFoundation
import Foundation

nonisolated enum HostMigrationPreferences {
    static let keys = ["rateDisplayUnit", "dataDisplayUnit", "keepAwake.presets.v1", "keepAwake.keepDisplayOn.v1",
                       "notifications.enabled.v1", "notifications.keepAwakeTimer.v1", "speech.transcriptionLanguage.v1"]

    static func validated(_ data: Data) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HostMigrationError.invalidSource
        }
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = values[key] else { continue }
            switch key {
            case "rateDisplayUnit":
                guard let text = value as? String, ["megabitsPerSecond", "megabytesPerSecond"].contains(text) else {
                    throw HostMigrationError.invalidSource
                }
            case "dataDisplayUnit":
                guard let text = value as? String, DataDisplayUnit(rawValue: text) != nil else { throw HostMigrationError.invalidSource }
            case "speech.transcriptionLanguage.v1":
                guard let text = value as? String, ["en", "ur"].contains(text) else { throw HostMigrationError.invalidSource }
            case "keepAwake.presets.v1":
                guard let bytes = value as? Data else { throw HostMigrationError.invalidSource }
                _ = try KeepAwakePresetConfiguration(validating: JSONDecoder().decode([KeepAwakePreset].self, from: bytes))
            default:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw HostMigrationError.invalidSource
                }
            }
            result[key] = value
        }
        return result
    }

    static func encode(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
}
