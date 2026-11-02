import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct TranscriptionLanguagePreferenceStoreTests {
    @MainActor
    private final class PreferencesFixture {
        let suiteName = "MacUtilities.TranscriptionLanguageTests.\(UUID().uuidString)"
        let preferences: UserDefaults

        init() {
            preferences = UserDefaults(suiteName: suiteName)!
            preferences.removePersistentDomain(forName: suiteName)
        }

        func remove() {
            preferences.removePersistentDomain(forName: suiteName)
        }
    }

    @Test
    func languagesExposeOnlyTheirExplicitCodesAndNames() {
        #expect(TranscriptionLanguage.allCases == [.english, .urdu])
        #expect(TranscriptionLanguage.english.rawValue == "en")
        #expect(TranscriptionLanguage.english.displayName == "English")
        #expect(TranscriptionLanguage.urdu.rawValue == "ur")
        #expect(TranscriptionLanguage.urdu.displayName == "Urdu")
    }

    @Test
    func missingSelectionDefaultsToEnglishWithoutPersistingIt() {
        let fixture = PreferencesFixture()
        defer { fixture.remove() }

        let store = TranscriptionLanguagePreferenceStore(preferences: fixture.preferences)

        #expect(store.selectedLanguage == .english)
        #expect(fixture.preferences.object(forKey: TranscriptionLanguagePreferenceStore.selectedLanguagePreferenceKey) == nil)
    }

    @Test
    func selectedLanguagesPersistAcrossPreferenceStoreInstances() {
        let fixture = PreferencesFixture()
        defer { fixture.remove() }

        let firstLaunch = TranscriptionLanguagePreferenceStore(preferences: fixture.preferences)
        firstLaunch.selectedLanguage = .urdu

        let secondLaunch = TranscriptionLanguagePreferenceStore(preferences: fixture.preferences)
        #expect(secondLaunch.selectedLanguage == .urdu)

        secondLaunch.selectedLanguage = .english
        let thirdLaunch = TranscriptionLanguagePreferenceStore(preferences: fixture.preferences)
        #expect(thirdLaunch.selectedLanguage == .english)
    }

    @Test
    func unsupportedOrAutomaticValueFallsBackToEnglish() {
        let fixture = PreferencesFixture()
        defer { fixture.remove() }
        fixture.preferences.set("auto", forKey: TranscriptionLanguagePreferenceStore.selectedLanguagePreferenceKey)

        let store = TranscriptionLanguagePreferenceStore(preferences: fixture.preferences)

        #expect(store.selectedLanguage == .english)
    }
}
