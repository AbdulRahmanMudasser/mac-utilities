import CryptoKit
import Foundation
import Testing
@testable import Mac_Utilities

struct SpeechModelStoreTests {
    @Test
    func cancelledImportDoesNotPublishOrCreateStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("trusted fixture bytes".utf8)
        try fixture.writeSource(payload)
        let store = fixture.store(for: payload)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled import must not publish a model.")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectoryURL.path))
        }
    }

    @Test
    func verifiedImportPublishesAtomicallyAndCanBeLeased() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("small test checkpoint".utf8)
        try fixture.writeSource(payload)
        let store = fixture.store(for: payload)

        let result = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        let repeatedResult = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        let destinationURL = fixture.destinationURL
        let storedPayload = try await store.withModel(forLanguageCode: "en") { url in
            try Data(contentsOf: url)
        }

        #expect(result == .installed)
        #expect(repeatedResult == .alreadyCurrent)
        #expect(storedPayload == payload)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test
    func vadImportUsesSharedAtomicIntegrityPathAndCanBeLeased() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("small test VAD checkpoint".utf8)
        try fixture.writeSource(payload)
        let store = fixture.vadStore(for: payload)

        let result = try await store.importModel(for: .vad, from: fixture.sourceURL)
        let repeatedResult = try await store.importModel(for: .vad, from: fixture.sourceURL)
        let storedPayload = try await store.withModel(for: .vad) { url in
            try Data(contentsOf: url)
        }

        #expect(result == .installed)
        #expect(repeatedResult == .alreadyCurrent)
        #expect(storedPayload == payload)
        #expect(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test
    func wrongChecksumIsRejectedWithoutPublishingPartialFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expectedPayload = Data("trusted fixture bytes".utf8)
        let wrongPayload = Data("trusted fixture bytez".utf8)
        #expect(expectedPayload.count == wrongPayload.count)
        try fixture.writeSource(wrongPayload)
        let store = fixture.store(for: expectedPayload)

        var failure: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        } catch {
            failure = error
        }

        #expect(failure as? SpeechModelStoreError == .checksumMismatch(
            expected: Self.sha256(expectedPayload),
            actual: Self.sha256(wrongPayload)
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test
    func failedReimportPreservesPreviouslyValidAsset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trustedPayload = Data("trusted fixture bytes".utf8)
        let wrongPayload = Data("trusted fixture bytez".utf8)
        try fixture.writeSource(trustedPayload)
        let store = fixture.store(for: trustedPayload)

        _ = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        try fixture.writeSource(wrongPayload)

        var failure: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        } catch {
            failure = error
        }
        let retainedPayload = try await store.withModel(forLanguageCode: "en") { url in
            try Data(contentsOf: url)
        }

        #expect(failure as? SpeechModelStoreError == .checksumMismatch(
            expected: Self.sha256(trustedPayload),
            actual: Self.sha256(wrongPayload)
        ))
        #expect(retainedPayload == trustedPayload)
        #expect(try fixture.partialFiles().isEmpty)
    }

    @Test
    func importCannotReplaceModelWhileAUseLeaseIsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("trusted fixture bytes".utf8)
        try fixture.writeSource(payload)
        let store = fixture.store(for: payload)
        _ = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)

        let gate = UseGate()
        let useTask = Task {
            try await store.withModel(forLanguageCode: "en") { modelURL in
                await gate.enterAndWait()
                return modelURL
            }
        }
        await gate.waitUntilEntered()

        var failure: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "en", from: fixture.sourceURL)
        } catch {
            failure = error
        }

        await gate.release()
        let leasedURL = try await useTask.value

        #expect(failure as? SpeechModelStoreError == .assetInUse)
        #expect(try Data(contentsOf: leasedURL) == payload)
    }

    @Test
    func vadImportCannotReplaceAssetWhileItsUseLeaseIsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("small test VAD checkpoint".utf8)
        try fixture.writeSource(payload)
        let store = fixture.vadStore(for: payload)
        _ = try await store.importModel(for: .vad, from: fixture.sourceURL)

        let gate = UseGate()
        let useTask = Task {
            try await store.withModel(for: .vad) { modelURL in
                await gate.enterAndWait()
                return modelURL
            }
        }
        await gate.waitUntilEntered()

        var failure: Error?
        do {
            _ = try await store.importModel(for: .vad, from: fixture.sourceURL)
        } catch {
            failure = error
        }

        await gate.release()
        let leasedURL = try await useTask.value

        #expect(failure as? SpeechModelStoreError == .assetInUse)
        #expect(try Data(contentsOf: leasedURL) == payload)
    }

    @Test
    func symlinkSourceIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("trusted fixture bytes".utf8)
        try fixture.writeSource(payload)
        let linkURL = fixture.baseURL.appendingPathComponent("model-link.bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fixture.sourceURL)
        let store = fixture.store(for: payload)

        var failure: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "en", from: linkURL)
        } catch {
            failure = error
        }

        #expect(failure as? SpeechModelStoreError == .unsafeSourceFile)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    }

    @Test
    func urduImportRejectsUnverifiedCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data("candidate model".utf8)
        try fixture.writeSource(payload)
        let store = SpeechModelStore(rootURL: fixture.modelDirectoryURL)

        var failure: Error?
        do {
            _ = try await store.importModel(forLanguageCode: "ur", from: fixture.sourceURL)
        } catch {
            failure = error
        }

        #expect(failure as? SpeechModelStoreError == .sourceByteCountMismatch(
            expected: SpeechModelMetadata.pinnedUrdu.expectedByteCount, actual: Int64(payload.count)
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectoryURL.appendingPathComponent(SpeechModelMetadata.pinnedUrdu.fileName).path))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        let baseURL: URL
        let modelDirectoryURL: URL
        let sourceURL: URL
        let destinationURL: URL

        init() throws {
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-model-store-\(UUID().uuidString)", isDirectory: true)
            modelDirectoryURL = baseURL.appendingPathComponent("models", isDirectory: true)
            sourceURL = baseURL.appendingPathComponent("source.bin", isDirectory: false)
            destinationURL = modelDirectoryURL.appendingPathComponent("fixture-model.bin", isDirectory: false)
            try FileManager.default.createDirectory(
                at: baseURL,
                withIntermediateDirectories: true
            )
        }

        func store(for payload: Data) -> SpeechModelStore {
            let metadata = SpeechModelMetadata(
                languageCode: "en",
                modelName: "Isolated test model",
                sourceRepository: URL(string: "https://huggingface.co/test/speech-models")!,
                revision: String(repeating: "a", count: 40),
                fileName: "fixture-model.bin",
                expectedByteCount: Int64(payload.count),
                sha256: Self.sha256(payload),
                licenseIdentifier: "test-only"
            )
            return SpeechModelStore(
                rootURL: modelDirectoryURL,
                catalog: SpeechModelCatalog.testing(englishMetadata: metadata)
            )
        }

        func vadStore(for payload: Data) -> SpeechModelStore {
            let metadata = SpeechModelMetadata(
                asset: .vad,
                modelName: "Isolated test VAD model",
                sourceRepository: URL(string: "https://huggingface.co/test/speech-models")!,
                revision: String(repeating: "b", count: 40),
                fileName: "fixture-model.bin",
                expectedByteCount: Int64(payload.count),
                sha256: Self.sha256(payload),
                licenseIdentifier: "test-only"
            )
            return SpeechModelStore(
                rootURL: modelDirectoryURL,
                catalog: SpeechModelCatalog.testing(
                    englishMetadata: .pinnedEnglish,
                    vadMetadata: metadata
                )
            )
        }

        func writeSource(_ data: Data) throws {
            try data.write(to: sourceURL, options: .atomic)
        }

        func partialFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: modelDirectoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix(".partial") }
        }

        func remove() {
            try? FileManager.default.removeItem(at: baseURL)
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private actor UseGate {
        private var entered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func enterAndWait() async {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }
}
