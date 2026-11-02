import Foundation

nonisolated enum SpeechAssetAcquisitionError: Error, Equatable, LocalizedError, Sendable {
    case languageUnavailable(String)
    case alreadyInProgress
    case missingPinnedArtifactURL(SpeechModelAsset)
    case invalidHTTPResponse(SpeechModelAsset)
    case httpStatus(SpeechModelAsset, Int)
    case downloadExceedsPinnedSize(SpeechModelAsset, expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .languageUnavailable(let languageCode):
            if languageCode == "ur" {
                "The Urdu model is not installed. Select its downloaded model file to continue."
            } else {
                "Automatic speech asset acquisition is not configured for language code \(languageCode)."
            }
        case .alreadyInProgress:
            "Speech asset acquisition is already in progress."
        case .missingPinnedArtifactURL(let asset):
            "The pinned download address for the \(asset.displayName) is invalid."
        case .invalidHTTPResponse(let asset):
            "The download for the \(asset.displayName) did not return a valid HTTP response."
        case .httpStatus(let asset, let status):
            "The download for the \(asset.displayName) failed with HTTP status \(status)."
        case .downloadExceedsPinnedSize(let asset, let expected, let actual):
            "The \(asset.displayName) download exceeded its pinned size of \(expected) bytes (the response reported or delivered \(actual) bytes)."
        }
    }
}

nonisolated enum SpeechAssetAcquisitionProgress: Equatable, Sendable {
    case checking(SpeechModelAsset)
    case downloading(SpeechModelAsset, receivedByteCount: Int64, expectedByteCount: Int64)
    case verifying(SpeechModelAsset)
    case ready(SpeechModelAsset, SpeechModelImportResult)
    case failed(SpeechModelAsset)
    case cancelled(SpeechModelAsset)
    case complete
}

nonisolated struct SpeechAssetAcquisitionResult: Equatable, Sendable {
    let transcription: SpeechModelImportResult
    let vad: SpeechModelImportResult
}

nonisolated protocol SpeechAssetDownloadClient: Sendable {
    func download(
        from url: URL,
        for asset: SpeechModelAsset,
        maximumByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL
}

nonisolated final class URLSessionSpeechAssetDownloadClient: SpeechAssetDownloadClient, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let temporaryDirectoryURL: URL

    convenience init(session: URLSession) {
        self.init(configuration: session.configuration)
    }

    init(
        configuration: URLSessionConfiguration,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.configuration = Self.credentialFreeCopy(of: configuration)
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func download(
        from url: URL,
        for asset: SpeechModelAsset,
        maximumByteCount: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              maximumByteCount > 0 else {
            throw SpeechAssetAcquisitionError.missingPinnedArtifactURL(asset)
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60 * 60
        )
        request.httpShouldHandleCookies = false
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let transfer = SpeechAssetURLSessionDownloadTransfer(
            asset: asset,
            maximumByteCount: maximumByteCount,
            temporaryDirectoryURL: temporaryDirectoryURL,
            progress: progress
        )
        return try await transfer.download(request: request, configuration: configuration)
    }

    private static func credentialFreeCopy(of configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.urlCache = nil
        copy.httpAdditionalHeaders = nil
        return copy
    }
}

nonisolated private final class SpeechAssetURLSessionDownloadTransfer: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let asset: SpeechModelAsset
    private let maximumByteCount: Int64
    private let temporaryDirectoryURL: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancellationRequested = false
    private var isFinished = false
    private var exceededByteCount: Int64?
    private var rejectedHTTPStatus: Int?
    private var ownedTemporaryURL: URL?
    private var fileMoveError: Error?

    init(
        asset: SpeechModelAsset,
        maximumByteCount: Int64,
        temporaryDirectoryURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.asset = asset
        self.maximumByteCount = maximumByteCount
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.progress = progress
    }

    func download(request: URLRequest, configuration: URLSessionConfiguration) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func begin(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        continuation: CheckedContinuation<URL, Error>
    ) {
        lock.lock()
        guard !cancellationRequested else {
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
        lock.unlock()
    }

    private func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let shouldOwnFile = !isFinished
            && !cancellationRequested
            && exceededByteCount == nil
            && rejectedHTTPStatus == nil
        lock.unlock()
        guard shouldOwnFile else { return }

        let ownedURL = temporaryDirectoryURL
            .appendingPathComponent("speech-asset-download-\(UUID().uuidString)", isDirectory: false)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            if let fileByteCount = (attributes[.size] as? NSNumber)?.int64Value,
               fileByteCount > maximumByteCount {
                lock.lock()
                if !isFinished, !cancellationRequested, exceededByteCount == nil {
                    exceededByteCount = fileByteCount
                }
                lock.unlock()
                downloadTask.cancel()
                return
            }

            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: ownedURL)

            lock.lock()
            if isFinished || cancellationRequested || exceededByteCount != nil || rejectedHTTPStatus != nil {
                lock.unlock()
                try? FileManager.default.removeItem(at: ownedURL)
            } else {
                ownedTemporaryURL = ownedURL
                lock.unlock()
            }
        } catch {
            lock.lock()
            if !isFinished {
                fileMoveError = error
            }
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var shouldCancel = false
        var progressByteCount: Int64?

        lock.lock()
        guard !isFinished, !cancellationRequested else {
            lock.unlock()
            return
        }

        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            rejectedHTTPStatus = response.statusCode
            shouldCancel = true
        } else if totalBytesWritten > maximumByteCount
                    || totalBytesExpectedToWrite > maximumByteCount {
            if exceededByteCount == nil {
                exceededByteCount = max(totalBytesWritten, totalBytesExpectedToWrite)
            }
            shouldCancel = true
        } else {
            progressByteCount = totalBytesWritten
        }
        lock.unlock()

        if shouldCancel {
            downloadTask.cancel()
        } else if let progressByteCount {
            progress(progressByteCount)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let response = task.response as? HTTPURLResponse

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true

        let continuation = self.continuation
        self.continuation = nil
        let exceededByteCount = self.exceededByteCount
        let cancellationRequested = self.cancellationRequested
        let rejectedHTTPStatus = self.rejectedHTTPStatus
        let ownedURL = self.ownedTemporaryURL
        self.ownedTemporaryURL = nil
        let fileMoveError = self.fileMoveError
        let completedSession = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        let result: Result<URL, Error>
        if let exceededByteCount {
            result = .failure(SpeechAssetAcquisitionError.downloadExceedsPinnedSize(
                asset,
                expected: maximumByteCount,
                actual: exceededByteCount
            ))
        } else if cancellationRequested {
            result = .failure(CancellationError())
        } else if let status = rejectedHTTPStatus ?? response?.statusCode,
                  !(200..<300).contains(status) {
            result = .failure(SpeechAssetAcquisitionError.httpStatus(asset, status))
        } else if let error {
            result = .failure(error)
        } else if response == nil {
            result = .failure(SpeechAssetAcquisitionError.invalidHTTPResponse(asset))
        } else if let fileMoveError {
            result = .failure(fileMoveError)
        } else if let ownedURL {
            result = .success(ownedURL)
        } else {
            result = .failure(SpeechAssetAcquisitionError.invalidHTTPResponse(asset))
        }

        if case .failure = result, let ownedURL {
            try? FileManager.default.removeItem(at: ownedURL)
        }
        if let continuation {
            continuation.resume(with: result)
        } else if case let .success(ownedURL) = result {
            try? FileManager.default.removeItem(at: ownedURL)
        }
        completedSession?.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.user == nil,
              request.url?.password == nil else {
            completionHandler(nil)
            return
        }

        var sanitizedRequest = request
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        sanitizedRequest.httpShouldHandleCookies = false
        completionHandler(sanitizedRequest)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolveAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolveAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    private func resolveAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}

actor SpeechAssetAcquisition {
    private let store: SpeechModelStore
    private let catalog: SpeechModelCatalog
    private let downloader: any SpeechAssetDownloadClient
    private var isAcquiring = false

    init(
        store: SpeechModelStore,
        catalog: SpeechModelCatalog = .pinned,
        downloader: any SpeechAssetDownloadClient
    ) {
        self.store = store
        self.catalog = catalog
        self.downloader = downloader
    }

    init(
        store: SpeechModelStore,
        catalog: SpeechModelCatalog = .pinned,
        session: URLSession
    ) {
        self.store = store
        self.catalog = catalog
        downloader = URLSessionSpeechAssetDownloadClient(session: session)
    }

    func importUrduModel(from url: URL) async throws {
        guard !isAcquiring else { throw SpeechAssetAcquisitionError.alreadyInProgress }
        isAcquiring = true
        defer { isAcquiring = false }
        _ = try await store.importModel(forLanguageCode: "ur", from: url)
    }

    func acquireAssets(
        forLanguageCode languageCode: String = "en",
        progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void = { _ in }
    ) async throws -> SpeechAssetAcquisitionResult {
        guard languageCode == "en" || languageCode == "ur" else {
            throw SpeechAssetAcquisitionError.languageUnavailable(languageCode)
        }
        guard !isAcquiring else { throw SpeechAssetAcquisitionError.alreadyInProgress }
        isAcquiring = true
        defer { isAcquiring = false }

        let transcription = try await acquire(
            .transcription(languageCode: languageCode),
            progress: progress
        )
        let vad = try await acquire(.vad, progress: progress)
        progress(.complete)
        return SpeechAssetAcquisitionResult(transcription: transcription, vad: vad)
    }

    private func acquire(
        _ asset: SpeechModelAsset,
        progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void
    ) async throws -> SpeechModelImportResult {
        progress(.checking(asset))
        do {
            try Task.checkCancellation()
            let metadata: SpeechModelMetadata
            switch catalog.availability(for: asset) {
            case .available(let availableMetadata):
                metadata = availableMetadata
            case .unavailable(let reason):
                switch asset {
                case .transcription(let languageCode):
                    throw SpeechModelStoreError.modelUnavailable(
                        languageCode: languageCode,
                        reason: reason
                    )
                case .vad:
                    throw SpeechModelStoreError.assetUnavailable(asset: asset, reason: reason)
                }
            }

            if try await isAlreadyInstalled(asset) {
                progress(.ready(asset, .alreadyCurrent))
                return .alreadyCurrent
            }

            if asset == .transcription(languageCode: "ur") {
                throw SpeechAssetAcquisitionError.languageUnavailable("ur")
            }

            guard let artifactURL = metadata.pinnedArtifactURL else {
                throw SpeechAssetAcquisitionError.missingPinnedArtifactURL(asset)
            }
            progress(.downloading(asset, receivedByteCount: 0, expectedByteCount: metadata.expectedByteCount))
            let downloadedURL = try await downloader.download(
                from: artifactURL,
                for: asset,
                maximumByteCount: metadata.expectedByteCount,
                progress: { receivedByteCount in
                    progress(.downloading(
                        asset,
                        receivedByteCount: receivedByteCount,
                        expectedByteCount: metadata.expectedByteCount
                    ))
                }
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }

            try Task.checkCancellation()
            progress(.verifying(asset))
            let result = try await store.importModel(for: asset, from: downloadedURL)
            progress(.ready(asset, result))
            return result
        } catch {
            progress(Task.isCancelled || error is CancellationError ? .cancelled(asset) : .failed(asset))
            throw error
        }
    }

    private func isAlreadyInstalled(_ asset: SpeechModelAsset) async throws -> Bool {
        do {
            try await store.withModel(for: asset) { _ in () }
            return true
        } catch let error as SpeechModelStoreError {
            switch error {
            case .modelNotInstalled, .installedModelInvalid:
                return false
            default:
                throw error
            }
        }
    }
}

nonisolated final class SpeechAssetInferenceFactory: @unchecked Sendable {
    private let store: SpeechModelStore

    init(store: SpeechModelStore) {
        self.store = store
    }

    func withInference<Result: Sendable>(
        forLanguageCode languageCode: String,
        operation: @Sendable (WhisperInference) async throws -> Result
    ) async throws -> Result {
        try await withVerifiedAssets(forLanguageCode: languageCode) { modelURL, vadURL in
            try Task.checkCancellation()
            let inference = try WhisperInference(verifiedModelURL: modelURL, vadModelURL: vadURL)
            try Task.checkCancellation()
            return try await operation(inference)
        }
    }

    func withVerifiedAssets<Result: Sendable>(
        forLanguageCode languageCode: String,
        operation: @Sendable (URL, URL) async throws -> Result
    ) async throws -> Result {
        try await store.withModel(forLanguageCode: languageCode) { modelURL in
            try await store.withModel(for: .vad) { vadURL in
                try await operation(modelURL, vadURL)
            }
        }
    }
}
