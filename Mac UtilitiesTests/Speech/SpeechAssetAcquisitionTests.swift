import CryptoKit
import Foundation
import Testing
@testable import Mac_Utilities

struct SpeechAssetAcquisitionTests {
    @Test
    func explicitSetupDownloadsAndPublishesEnglishAndVADWithTruthfulProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("small verified english model".utf8)
        let vadBytes = Data("small verified VAD model".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(
            directoryURL: fixture.downloadDirectoryURL,
            englishBytes: englishBytes,
            vadBytes: vadBytes
        )
        let acquisition = SpeechAssetAcquisition(
            store: store,
            catalog: catalog,
            downloader: downloader
        )
        let progress = ProgressRecorder()

        let result = try await acquisition.acquireAssets { progress.append($0) }
        let requests = await downloader.requestedAssets()
        let downloadedURLs = await downloader.downloadedURLs()
        let events = progress.snapshot

        #expect(result == SpeechAssetAcquisitionResult(transcription: .installed, vad: .installed))
        #expect(requests == [.transcription(languageCode: "en"), .vad])
        #expect(events.contains(.checking(.transcription(languageCode: "en"))))
        #expect(events.contains(.checking(.vad)))
        #expect(events.contains(.verifying(.transcription(languageCode: "en"))))
        #expect(events.contains(.verifying(.vad)))
        #expect(events.contains(.ready(.transcription(languageCode: "en"), .installed)))
        #expect(events.contains(.ready(.vad, .installed)))
        #expect(events.last == .complete)
        #expect(downloadedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try fixture.partialFiles().isEmpty)

        let installedEnglish = try await store.withModel(forLanguageCode: "en") {
            try Data(contentsOf: $0)
        }
        let installedVAD = try await store.withModel(for: .vad) {
            try Data(contentsOf: $0)
        }
        #expect(installedEnglish == englishBytes)
        #expect(installedVAD == vadBytes)
    }

    @Test
    func validInstalledAssetsAreReusedWithoutAnotherDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("existing english asset".utf8)
        let vadBytes = Data("existing VAD asset".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(
            directoryURL: fixture.downloadDirectoryURL,
            englishBytes: englishBytes,
            vadBytes: vadBytes
        )
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)

        _ = try await acquisition.acquireAssets()
        let repeated = try await acquisition.acquireAssets()

        #expect(repeated == SpeechAssetAcquisitionResult(transcription: .alreadyCurrent, vad: .alreadyCurrent))
        #expect(await downloader.requestedAssets() == [.transcription(languageCode: "en"), .vad])
    }

    @Test
    func checksumFailureDoesNotPublishAndRemovesTheDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pinnedEnglish = Data("trusted-model".utf8)
        let wrongEnglish = Data("trusted-m0del".utf8)
        let vadBytes = Data("trusted-vad".utf8)
        let catalog = fixture.catalog(englishBytes: pinnedEnglish, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(
            directoryURL: fixture.downloadDirectoryURL,
            englishBytes: wrongEnglish,
            vadBytes: vadBytes
        )
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)
        let progress = ProgressRecorder()

        var failure: Error?
        do {
            _ = try await acquisition.acquireAssets { progress.append($0) }
        } catch {
            failure = error
        }

        #expect(failure as? SpeechModelStoreError == .checksumMismatch(
            expected: Self.sha256(pinnedEnglish),
            actual: Self.sha256(wrongEnglish)
        ))
        #expect(progress.snapshot.contains(.failed(.transcription(languageCode: "en"))))
        #expect(await downloader.downloadedURLs().allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectoryURL
            .appendingPathComponent(catalog.englishMetadata.fileName).path))
        #expect(try fixture.partialFiles().isEmpty)
        #expect(await downloader.requestedAssets() == [.transcription(languageCode: "en")])
    }

    @Test
    func missingUrduFailsClosedWithoutNetworkAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("english".utf8)
        let vadBytes = Data("vad".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(
            directoryURL: fixture.downloadDirectoryURL,
            englishBytes: englishBytes,
            vadBytes: vadBytes
        )
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)

        var failure: Error?
        do {
            _ = try await acquisition.acquireAssets(forLanguageCode: "ur")
        } catch {
            failure = error
        }

        #expect(failure as? SpeechAssetAcquisitionError == .languageUnavailable("ur"))
        #expect(await downloader.requestedAssets().isEmpty)
    }

    @Test @MainActor
    func cancellingUrduFileSelectionDoesNotDownloadOrInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("english".utf8)
        let vadBytes = Data("vad".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(directoryURL: fixture.downloadDirectoryURL, englishBytes: englishBytes, vadBytes: vadBytes)
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)
        let setup = SpeechAssetTranscribeSetup(acquisition: acquisition, chooseUrduModel: { nil })

        do {
            try await setup.acquireAssets(for: .urdu, progress: { _ in })
            Issue.record("Cancelling model selection must cancel setup.")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected setup error: \(error)")
        }
        #expect(await downloader.requestedAssets().isEmpty)
    }

    @Test @MainActor
    func selectingAnInvalidUrduFileDoesNotInstallOrDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("english".utf8)
        let vadBytes = Data("vad".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let downloader = FakeDownloader(directoryURL: fixture.downloadDirectoryURL, englishBytes: englishBytes, vadBytes: vadBytes)
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)
        let invalidFile = try fixture.writeSource(Data("wrong model".utf8), name: "wrong.bin")
        let setup = SpeechAssetTranscribeSetup(acquisition: acquisition, chooseUrduModel: { invalidFile })

        do {
            try await setup.acquireAssets(for: .urdu, progress: { _ in })
            Issue.record("An invalid Urdu model must not be installed.")
        } catch let error as SpeechModelStoreError {
            guard case .sourceByteCountMismatch = error else {
                Issue.record("Unexpected model validation error: \(error)")
                return
            }
        }
        #expect(await downloader.requestedAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectoryURL.appendingPathComponent(SpeechModelMetadata.pinnedUrdu.fileName).path))
    }

    @Test
    func cancellationStopsTheDownloadAndReportsCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("english".utf8)
        let vadBytes = Data("vad".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let gate = DownloadStartGate()
        let downloader = BlockingDownloader(gate: gate)
        let acquisition = SpeechAssetAcquisition(store: store, catalog: catalog, downloader: downloader)
        let progress = ProgressRecorder()
        let task = Task {
            try await acquisition.acquireAssets { progress.append($0) }
        }

        await gate.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must stop the active asset download.")
        } catch is CancellationError {
            // Expected.
        }

        #expect(progress.snapshot.contains(.cancelled(.transcription(languageCode: "en"))))
        #expect(await downloader.requestCount() == 1)
    }

    @Test
    func urlSessionDownloaderReportsWriteProgressAndOwnsItsTemporaryFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x5A, count: 256 * 1024)
        let (downloader, url, route) = fixture.urlSessionDownloader(statusCode: 200, body: payload)
        defer { SpeechAssetStubRegistry.shared.removeResponse(for: route) }
        let progress = ByteProgressRecorder()

        let downloadedURL = try await downloader.download(
            from: url,
            for: .vad,
            maximumByteCount: Int64(payload.count),
            progress: { progress.append($0) }
        )

        #expect(downloadedURL.deletingLastPathComponent() == fixture.downloadDirectoryURL)
        #expect(try Data(contentsOf: downloadedURL) == payload)
        #expect(progress.snapshot.contains { $0 > 0 })
        #expect(progress.snapshot.last == Int64(payload.count))
        let requestHeaders = SpeechAssetStubRegistry.shared.requestHeaders(for: route)
        #expect(requestHeaders?.value(forCaseInsensitiveHeader: "Authorization") == nil)
        #expect(requestHeaders?.value(forCaseInsensitiveHeader: "Cookie") == nil)

        try FileManager.default.removeItem(at: downloadedURL)
        #expect(try fixture.downloadedFiles().isEmpty)
    }

    @Test
    func urlSessionDownloaderCancelsWhenTheResponseExceedsThePinnedSize() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x2A, count: 64 * 1024)
        let (downloader, url, route) = fixture.urlSessionDownloader(statusCode: 200, body: payload)
        defer { SpeechAssetStubRegistry.shared.removeResponse(for: route) }
        let maximumByteCount: Int64 = 4 * 1024
        let progress = ByteProgressRecorder()

        var failure: Error?
        do {
            _ = try await downloader.download(
                from: url,
                for: .vad,
                maximumByteCount: maximumByteCount,
                progress: { progress.append($0) }
            )
        } catch {
            failure = error
        }

        guard let acquisitionError = failure as? SpeechAssetAcquisitionError,
              case let .downloadExceedsPinnedSize(asset, expected, actual) = acquisitionError else {
            Issue.record("An oversized response must fail with the pinned-size error.")
            return
        }
        #expect(asset == .vad)
        #expect(expected == maximumByteCount)
        #expect(actual > maximumByteCount)
        #expect(progress.snapshot.allSatisfy { $0 <= maximumByteCount })
        #expect(try fixture.downloadedFiles().isEmpty)
    }

    @Test
    func urlSessionDownloaderRejectsHTTPFailuresAndCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("not found".utf8)
        let (downloader, url, route) = fixture.urlSessionDownloader(statusCode: 404, body: payload)
        defer { SpeechAssetStubRegistry.shared.removeResponse(for: route) }

        var failure: Error?
        do {
            _ = try await downloader.download(
                from: url,
                for: .vad,
                maximumByteCount: 1024,
                progress: { _ in }
            )
        } catch {
            failure = error
        }

        #expect(failure as? SpeechAssetAcquisitionError == .httpStatus(.vad, 404))
        #expect(try fixture.downloadedFiles().isEmpty)
    }

    @Test
    func urlSessionDownloaderCancellationCompletesAndCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data(repeating: 0x31, count: 128 * 1024)
        let (downloader, url, route) = fixture.urlSessionDownloader(
            statusCode: 200,
            body: payload,
            holdOpen: true
        )
        defer { SpeechAssetStubRegistry.shared.removeResponse(for: route) }
        let progressGate = DownloadStartGate()
        let task = Task<URL, Error> {
            try await downloader.download(
                from: url,
                for: .vad,
                maximumByteCount: Int64(payload.count),
                progress: { _ in Task { await progressGate.markStarted() } }
            )
        }

        await progressGate.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelling a URLSession download must complete with cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        #expect(try fixture.downloadedFiles().isEmpty)
    }

    @Test
    func inferenceFactoryHoldsBothVerifiedAssetLeasesForItsWholeCallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let englishBytes = Data("lease test english".utf8)
        let vadBytes = Data("lease test VAD".utf8)
        let catalog = fixture.catalog(englishBytes: englishBytes, vadBytes: vadBytes)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        let englishSource = try fixture.writeSource(englishBytes, name: "english-source.bin")
        let vadSource = try fixture.writeSource(vadBytes, name: "vad-source.bin")
        _ = try await store.importModel(forLanguageCode: "en", from: englishSource)
        _ = try await store.importModel(for: .vad, from: vadSource)

        let factory = SpeechAssetInferenceFactory(store: store)
        let gate = LeaseGate()
        let useTask = Task {
            try await factory.withVerifiedAssets(forLanguageCode: "en") { modelURL, vadURL in
                #expect(modelURL.lastPathComponent == catalog.englishMetadata.fileName)
                #expect(vadURL.lastPathComponent == catalog.vadMetadata.fileName)
                await gate.enterAndWait()
                return true
            }
        }
        await gate.waitUntilEntered()

        var englishReplacementError: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "en", from: englishSource)
        } catch {
            englishReplacementError = error
        }
        var vadReplacementError: Error?
        do {
            _ = try await store.importModel(for: .vad, from: vadSource)
        } catch {
            vadReplacementError = error
        }

        await gate.release()
        #expect(try await useTask.value)
        #expect(englishReplacementError as? SpeechModelStoreError == .assetInUse)
        #expect(vadReplacementError as? SpeechModelStoreError == .assetInUse)
    }

    @Test
    func inferenceFactoryRejectsMissingUrduModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = fixture.catalog(
            englishBytes: Data("english".utf8),
            vadBytes: Data("vad".utf8)
        )
        let factory = SpeechAssetInferenceFactory(
            store: SpeechModelStore(rootURL: fixture.modelDirectoryURL, catalog: catalog)
        )

        var failure: Error?
        do {
            _ = try await factory.withVerifiedAssets(forLanguageCode: "ur") { _, _ in true }
        } catch {
            failure = error
        }

        #expect(failure as? SpeechModelStoreError == .modelNotInstalled)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        let baseURL: URL
        let modelDirectoryURL: URL
        let downloadDirectoryURL: URL

        init() throws {
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-asset-acquisition-\(UUID().uuidString)", isDirectory: true)
            modelDirectoryURL = baseURL.appendingPathComponent("models", isDirectory: true)
            downloadDirectoryURL = baseURL.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadDirectoryURL,
                withIntermediateDirectories: true
            )
        }

        func catalog(englishBytes: Data, vadBytes: Data) -> SpeechModelCatalog {
            SpeechModelCatalog.testing(
                englishMetadata: metadata(
                    asset: .transcription(languageCode: "en"),
                    name: "English test model",
                    fileName: "english-test.bin",
                    bytes: englishBytes
                ),
                vadMetadata: metadata(
                    asset: .vad,
                    name: "VAD test model",
                    fileName: "vad-test.bin",
                    bytes: vadBytes
                )
            )
        }

        func metadata(
            asset: SpeechModelAsset,
            name: String,
            fileName: String,
            bytes: Data
        ) -> SpeechModelMetadata {
            let repository = asset == .vad
                ? URL(string: "https://huggingface.co/test/vad")!
                : URL(string: "https://huggingface.co/test/english")!
            return SpeechModelMetadata(
                asset: asset,
                modelName: name,
                sourceRepository: repository,
                revision: String(repeating: "a", count: 40),
                fileName: fileName,
                expectedByteCount: Int64(bytes.count),
                sha256: Self.sha256(bytes),
                licenseIdentifier: "MIT"
            )
        }

        func writeSource(_ data: Data, name: String) throws -> URL {
            let url = baseURL.appendingPathComponent(name, isDirectory: false)
            try data.write(to: url)
            return url
        }

        func partialFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: modelDirectoryURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".partial") }
        }

        func downloadedFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: downloadDirectoryURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("speech-asset-download-") }
        }

        func urlSessionDownloader(
            statusCode: Int,
            body: Data,
            holdOpen: Bool = false
        ) -> (URLSessionSpeechAssetDownloadClient, URL, String) {
            let route = "/speech-asset-\(UUID().uuidString)"
            let url = URL(string: "https://speech-assets.test\(route)")!
            SpeechAssetStubRegistry.shared.registerResponse(
                SpeechAssetStubResponse(statusCode: statusCode, body: body, holdOpen: holdOpen),
                for: route
            )

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SpeechAssetStubURLProtocol.self]
            configuration.httpAdditionalHeaders = [
                "Authorization": "Bearer test-only",
                "Cookie": "session=test-only"
            ]
            let downloader = URLSessionSpeechAssetDownloadClient(
                configuration: configuration,
                temporaryDirectoryURL: downloadDirectoryURL
            )
            return (downloader, url, route)
        }

        func remove() {
            try? FileManager.default.removeItem(at: baseURL)
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private nonisolated final class ByteProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func append(_ value: Int64) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private nonisolated final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SpeechAssetAcquisitionProgress] = []

        func append(_ value: SpeechAssetAcquisitionProgress) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [SpeechAssetAcquisitionProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private actor FakeDownloader: SpeechAssetDownloadClient {
        private let directoryURL: URL
        private let englishBytes: Data
        private let vadBytes: Data
        private var requests: [SpeechModelAsset] = []
        private var outputURLs: [URL] = []

        init(directoryURL: URL, englishBytes: Data, vadBytes: Data) {
            self.directoryURL = directoryURL
            self.englishBytes = englishBytes
            self.vadBytes = vadBytes
        }

        func download(
            from url: URL,
            for asset: SpeechModelAsset,
            maximumByteCount: Int64,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws -> URL {
            try Task.checkCancellation()
            requests.append(asset)
            let payload = asset == .vad ? vadBytes : englishBytes
            let fileURL = directoryURL.appendingPathComponent("download-\(UUID().uuidString).bin")
            try payload.write(to: fileURL)
            outputURLs.append(fileURL)
            progress(Int64(payload.count))
            return fileURL
        }

        func requestedAssets() -> [SpeechModelAsset] { requests }
        func downloadedURLs() -> [URL] { outputURLs }
    }

    private actor DownloadStartGate {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            started = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor BlockingDownloader: SpeechAssetDownloadClient {
        private let gate: DownloadStartGate
        private var requests = 0

        init(gate: DownloadStartGate) { self.gate = gate }

        func download(
            from url: URL,
            for asset: SpeechModelAsset,
            maximumByteCount: Int64,
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws -> URL {
            requests += 1
            await gate.markStarted()
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }

        func requestCount() -> Int { requests }
    }

    private actor LeaseGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            entered = true
            let pending = entryWaiters
            entryWaiters.removeAll()
            pending.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
}

private struct SpeechAssetStubResponse: Sendable {
    let statusCode: Int
    let body: Data
    let holdOpen: Bool
}

private nonisolated final class SpeechAssetStubRegistry: @unchecked Sendable {
    static let shared = SpeechAssetStubRegistry()

    private let lock = NSLock()
    private var responses: [String: SpeechAssetStubResponse] = [:]
    private var headersByRoute: [String: [String: String]] = [:]

    func registerResponse(_ response: SpeechAssetStubResponse, for route: String) {
        lock.lock()
        responses[route] = response
        headersByRoute.removeValue(forKey: route)
        lock.unlock()
    }

    func removeResponse(for route: String) {
        lock.lock()
        responses.removeValue(forKey: route)
        headersByRoute.removeValue(forKey: route)
        lock.unlock()
    }

    func response(for route: String) -> SpeechAssetStubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[route]
    }

    func record(headers: [String: String], for route: String) {
        lock.lock()
        headersByRoute[route] = headers
        lock.unlock()
    }

    func requestHeaders(for route: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return headersByRoute[route]
    }
}

private extension Dictionary where Key == String, Value == String {
    func value(forCaseInsensitiveHeader name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private nonisolated final class SpeechAssetStubURLProtocol: URLProtocol, @unchecked Sendable {
    private let stoppedLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "speech-assets.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = SpeechAssetStubRegistry.shared.response(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        SpeechAssetStubRegistry.shared.record(headers: headers, for: url.path)
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(response.body.count)]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        let chunkSize = 4 * 1024
        var offset = 0
        while offset < response.body.count {
            guard !isStopped else { return }
            let end = min(offset + chunkSize, response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
            if response.holdOpen { break }
        }

        guard !isStopped, !response.holdOpen else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stoppedLock.lock()
        stopped = true
        stoppedLock.unlock()
    }

    private var isStopped: Bool {
        stoppedLock.lock()
        defer { stoppedLock.unlock() }
        return stopped
    }
}
