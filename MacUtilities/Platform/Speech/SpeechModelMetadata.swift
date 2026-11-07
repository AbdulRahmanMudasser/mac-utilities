import Foundation

nonisolated enum SpeechModelAsset: Equatable, Sendable {
    case transcription(languageCode: String)
    case vad

    var isWellFormed: Bool {
        switch self {
        case .transcription(let languageCode):
            let bytes = Array(languageCode.utf8)
            return (bytes.count == 2 || bytes.count == 3) && bytes.allSatisfy {
                $0 >= 97 && $0 <= 122
            }
        case .vad:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .transcription(let languageCode):
            return "\(languageCode) speech model"
        case .vad:
            return "VAD model"
        }
    }
}

nonisolated struct SpeechModelMetadata: Equatable, Sendable {
    let asset: SpeechModelAsset
    let modelName: String
    let sourceRepository: URL
    let revision: String
    let fileName: String
    let repositoryFilePath: String
    let expectedByteCount: Int64
    let sha256: String
    let licenseIdentifier: String

    var languageCode: String? {
        guard case .transcription(let languageCode) = asset else { return nil }
        return languageCode
    }

    init(
        asset: SpeechModelAsset,
        modelName: String,
        sourceRepository: URL,
        revision: String,
        fileName: String,
        repositoryFilePath: String? = nil,
        expectedByteCount: Int64,
        sha256: String,
        licenseIdentifier: String
    ) {
        self.asset = asset
        self.modelName = modelName
        self.sourceRepository = sourceRepository
        self.revision = revision
        self.fileName = fileName
        self.repositoryFilePath = repositoryFilePath ?? fileName
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
        self.licenseIdentifier = licenseIdentifier
    }

    init(
        languageCode: String,
        modelName: String,
        sourceRepository: URL,
        revision: String,
        fileName: String,
        expectedByteCount: Int64,
        sha256: String,
        licenseIdentifier: String
    ) {
        self.init(
            asset: .transcription(languageCode: languageCode),
            modelName: modelName,
            sourceRepository: sourceRepository,
            revision: revision,
            fileName: fileName,
            expectedByteCount: expectedByteCount,
            sha256: sha256,
            licenseIdentifier: licenseIdentifier
        )
    }

    var pinnedArtifactURL: URL? {
        guard isWellFormed,
              var components = URLComponents(url: sourceRepository, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = "\(sourceRepository.path)/resolve/\(revision)/\(repositoryFilePath)"
        return components.url
    }

    var isWellFormed: Bool {
        asset.isWellFormed &&
            !modelName.isEmpty &&
            Self.isTrustedRepositoryURL(sourceRepository) &&
            Self.isLowercaseHex(revision, count: 40) &&
            Self.isSafeFileName(fileName) &&
            repositoryFilePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(Self.isSafeRepositoryComponent) &&
            expectedByteCount > 0 &&
            Self.isLowercaseHex(sha256, count: 64) &&
            !licenseIdentifier.isEmpty
    }

    static let pinnedEnglish = SpeechModelMetadata(
        asset: .transcription(languageCode: "en"),
        modelName: "Whisper Large V3 Turbo q5_0",
        sourceRepository: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!,
        revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        expectedByteCount: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        licenseIdentifier: "MIT"
    )

    static let pinnedVAD = SpeechModelMetadata(
        asset: .vad,
        modelName: "Silero VAD v6.2.0",
        sourceRepository: URL(string: "https://huggingface.co/ggml-org/whisper-vad")!,
        revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
        fileName: "ggml-silero-v6.2.0.bin",
        expectedByteCount: 885_098,
        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
        licenseIdentifier: "MIT"
    )

    static let pinnedUrdu = SpeechModelMetadata(
        asset: .transcription(languageCode: "ur"),
        modelName: "Urdu Sukhan ASR v1 q5_0",
        sourceRepository: URL(string: "https://huggingface.co/Loudness-ai/urdu-sukhan-asr-v1")!,
        revision: "f829afb90418c5cf29915f55761485b098a88142",
        fileName: "ggml-urdu-sukhan-asr-v1-q5_0.bin",
        repositoryFilePath: "ggml/ggml-urdu-sukhan-asr-v1-q5_0.bin",
        expectedByteCount: 574_041_195,
        sha256: "d2f57b59018992a09e90ea3692b1b589dac4813b2b508990fdda1d5ab10abb11",
        licenseIdentifier: "CC-BY-NC-4.0"
    )

    private static func isTrustedRepositoryURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "huggingface.co",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }

        let pathComponents = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.count == 3,
              pathComponents[0].isEmpty else {
            return false
        }

        return pathComponents[1...].allSatisfy(Self.isSafeRepositoryComponent)
    }

    private static func isSafeRepositoryComponent(_ value: Substring) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty &&
            value != "." &&
            value != ".." &&
            !value.contains("/") &&
            !value.contains("\\") &&
            !value.contains("\0") &&
            URL(fileURLWithPath: value).lastPathComponent == value
    }
}

nonisolated enum SpeechModelUnavailableReason: Equatable, Sendable {
    case trustedPinnedMetadataMissing
    case unsupportedLanguageCode
    case invalidPinnedMetadata
}

nonisolated enum SpeechModelAvailability: Equatable, Sendable {
    case available(SpeechModelMetadata)
    case unavailable(SpeechModelUnavailableReason)
}

nonisolated struct SpeechModelCatalog: Sendable {
    let englishMetadata: SpeechModelMetadata
    let vadMetadata: SpeechModelMetadata

    private init(englishMetadata: SpeechModelMetadata, vadMetadata: SpeechModelMetadata) {
        self.englishMetadata = englishMetadata
        self.vadMetadata = vadMetadata
    }

    func availability(forLanguageCode languageCode: String) -> SpeechModelAvailability {
        availability(for: .transcription(languageCode: languageCode))
    }

    func availability(for asset: SpeechModelAsset) -> SpeechModelAvailability {
        switch asset {
        case .transcription(let languageCode):
            switch languageCode {
            case "en":
                guard englishMetadata.asset == asset, englishMetadata.isWellFormed else {
                    return .unavailable(.invalidPinnedMetadata)
                }
                return .available(englishMetadata)
            case "ur":
                return .available(.pinnedUrdu)
            default:
                return .unavailable(.unsupportedLanguageCode)
            }
        case .vad:
            guard vadMetadata.asset == .vad, vadMetadata.isWellFormed else {
                return .unavailable(.invalidPinnedMetadata)
            }
            return .available(vadMetadata)
        }
    }

    static let pinned = SpeechModelCatalog(
        englishMetadata: .pinnedEnglish,
        vadMetadata: .pinnedVAD
    )

#if DEBUG
    static func testing(
        englishMetadata: SpeechModelMetadata,
        vadMetadata: SpeechModelMetadata = .pinnedVAD
    ) -> SpeechModelCatalog {
        SpeechModelCatalog(englishMetadata: englishMetadata, vadMetadata: vadMetadata)
    }
#endif
}
