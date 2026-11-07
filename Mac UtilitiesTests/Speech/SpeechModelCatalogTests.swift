import Foundation
import Testing
@testable import Mac_Utilities

struct SpeechModelCatalogTests {
    @Test
    func englishMetadataIsPinnedToTheVerifiedQ5Checkpoint() {
        let availability = SpeechModelCatalog.pinned.availability(forLanguageCode: "en")

        guard case .available(let metadata) = availability else {
            Issue.record("English must have trusted pinned metadata.")
            return
        }

        #expect(metadata.languageCode == "en")
        #expect(metadata.asset == .transcription(languageCode: "en"))
        #expect(metadata.modelName == "Whisper Large V3 Turbo q5_0")
        #expect(metadata.revision == "98aa99a0a9db05ae2342309f5096248665f7cba3")
        #expect(metadata.fileName == "ggml-large-v3-turbo-q5_0.bin")
        #expect(metadata.expectedByteCount == 574_041_195)
        #expect(metadata.sha256 == "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
        #expect(metadata.licenseIdentifier == "MIT")
        #expect(metadata.pinnedArtifactURL?.absoluteString ==
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin")
        #expect(metadata.isWellFormed)
    }

    @Test
    func vadMetadataIsPinnedToTheTrustedSileroArtifact() {
        let metadata = SpeechModelMetadata.pinnedVAD

        #expect(metadata.asset == .vad)
        #expect(metadata.languageCode == nil)
        #expect(metadata.modelName == "Silero VAD v6.2.0")
        #expect(metadata.sourceRepository.absoluteString == "https://huggingface.co/ggml-org/whisper-vad")
        #expect(metadata.revision == "9ffd54a1e1ee413ddf265af9913beaf518d1639b")
        #expect(metadata.fileName == "ggml-silero-v6.2.0.bin")
        #expect(metadata.expectedByteCount == 885_098)
        #expect(metadata.sha256 == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
        #expect(metadata.licenseIdentifier == "MIT")
        #expect(metadata.pinnedArtifactURL?.absoluteString ==
            "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")
        #expect(metadata.isWellFormed)
        #expect(SpeechModelCatalog.pinned.availability(for: .vad) == .available(metadata))
    }

    @Test
    func urduUsesTheApprovedPinnedModel() {
        #expect(
            SpeechModelCatalog.pinned.availability(forLanguageCode: TranscriptionLanguage.urdu.rawValue) ==
                .available(.pinnedUrdu)
        )
        #expect(SpeechModelMetadata.pinnedUrdu.pinnedArtifactURL?.absoluteString ==
            "https://huggingface.co/Loudness-ai/urdu-sukhan-asr-v1/resolve/f829afb90418c5cf29915f55761485b098a88142/ggml/ggml-urdu-sukhan-asr-v1-q5_0.bin")
    }

    @Test
    func existingLanguageCodesMapToTheirExplicitModelAvailability() {
        #expect(
            SpeechModelCatalog.pinned.availability(forLanguageCode: TranscriptionLanguage.english.rawValue) ==
                .available(.pinnedEnglish)
        )
        #expect(
            SpeechModelCatalog.pinned.availability(forLanguageCode: TranscriptionLanguage.urdu.rawValue) ==
                .available(.pinnedUrdu)
        )
    }

    @Test
    func unknownAndAutomaticLanguageCodesAreUnavailable() {
        #expect(
            SpeechModelCatalog.pinned.availability(forLanguageCode: "auto") ==
                .unavailable(.unsupportedLanguageCode)
        )
        #expect(
            SpeechModelCatalog.pinned.availability(forLanguageCode: "fr") ==
                .unavailable(.unsupportedLanguageCode)
        )
    }

    @Test
    func testingCatalogRejectsVADMetadataForAnotherAsset() {
        let catalog = SpeechModelCatalog.testing(
            englishMetadata: .pinnedEnglish,
            vadMetadata: .pinnedEnglish
        )

        #expect(catalog.availability(for: .vad) == .unavailable(.invalidPinnedMetadata))
    }
}
