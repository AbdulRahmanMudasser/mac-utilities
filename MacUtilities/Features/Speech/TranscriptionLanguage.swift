import Foundation

nonisolated enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case urdu = "ur"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .urdu: "Urdu"
        }
    }
}

@MainActor
final class TranscriptionLanguagePreferenceStore {
    static let selectedLanguagePreferenceKey = "speech.transcriptionLanguage.v1"

    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    var selectedLanguage: TranscriptionLanguage {
        get {
            guard let rawValue = preferences.string(forKey: Self.selectedLanguagePreferenceKey),
                  let language = TranscriptionLanguage(rawValue: rawValue) else {
                return .english
            }
            return language
        }
        set {
            preferences.set(newValue.rawValue, forKey: Self.selectedLanguagePreferenceKey)
        }
    }
}
