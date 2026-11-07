import AVFoundation
import AppKit
import AudioToolbox
import Darwin
import Dispatch
import Foundation
import Synchronization

nonisolated struct AudioCaptureChunk: Equatable, Sendable {
    let startingSampleIndex: UInt64
    let sampleRate: Double
    let samples: [Float]

    var channelCount: Int { 1 }
}

typealias AudioCaptureStream = AsyncThrowingStream<AudioCaptureChunk, any Error>

nonisolated enum AudioCaptureFailure: Error, Equatable, LocalizedError, Sendable {
    case microphonePermissionUndetermined
    case microphonePermissionDenied
    case alreadyCapturing
    case inputUnavailable
    case unsupportedInputFormat
    case invalidBufferPoolConfiguration
    case bufferAllocationFailed
    case inputBufferTooLarge
    case inputBufferUnavailable
    case captureOverloaded
    case conversionFailed
    case consumerTooSlow
    case inputConfigurationChanged
    case systemWillSleep
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionUndetermined:
            "Microphone access has not been granted."
        case .microphonePermissionDenied:
            "Microphone access is denied."
        case .alreadyCapturing:
            "Audio capture is already running."
        case .inputUnavailable:
            "No microphone input is available."
        case .unsupportedInputFormat:
            "The microphone input format is not supported."
        case .invalidBufferPoolConfiguration:
            "The audio capture buffer configuration is invalid."
        case .bufferAllocationFailed:
            "Audio capture could not allocate its bounded buffers."
        case .inputBufferTooLarge:
            "The microphone supplied an audio buffer larger than the capture limit."
        case .inputBufferUnavailable:
            "The microphone supplied audio without accessible sample data."
        case .captureOverloaded:
            "Audio capture could not keep up with microphone input."
        case .conversionFailed:
            "Microphone audio could not be converted to 16 kHz mono."
        case .consumerTooSlow:
            "The audio consumer could not keep up with microphone input."
        case .inputConfigurationChanged:
            "The microphone input changed. Start a new capture session."
        case .systemWillSleep:
            "Audio capture stopped because the Mac is going to sleep."
        case .engineStartFailed:
            "The audio capture engine could not start."
        }
    }
}

@MainActor
protocol AudioCapturing: AnyObject {
    var isCapturing: Bool { get }
    func start() throws -> AudioCaptureStream
    func stop() async
    func cancel() async
}

nonisolated enum AudioCaptureBounds {
    static let sampleRate = 16_000.0
    static let channelCount: AVAudioChannelCount = 1
    static let tapBufferSize: AVAudioFrameCount = 1_024
    static let maximumInputBufferDuration = 0.25
    static let maximumInputBufferBytesPerSlot: UInt64 = 1_048_576
    static let maximumInputChannels: AVAudioChannelCount = 8
    static let maximumPoolSlots = 4
    static let streamChunkCapacity = 8

    static func maximumInputFrameCapacity(for format: AVAudioFormat) -> AVAudioFrameCount? {
        guard format.sampleRate.isFinite,
              (8_000...384_000).contains(format.sampleRate),
              format.channelCount > 0,
              format.channelCount <= maximumInputChannels else {
            return nil
        }

        let bytesPerBufferFrame = UInt64(format.streamDescription.pointee.mBytesPerFrame)
        let buffersPerFrame = format.isInterleaved ? UInt64(1) : UInt64(format.channelCount)
        let (bytesPerInputFrame, multiplicationOverflow) =
            bytesPerBufferFrame.multipliedReportingOverflow(by: buffersPerFrame)
        guard !multiplicationOverflow, bytesPerInputFrame > 0 else { return nil }

        let durationFrameCount = floor(format.sampleRate * maximumInputBufferDuration)
        guard durationFrameCount.isFinite,
              durationFrameCount >= 1,
              durationFrameCount <= Double(AVAudioFrameCount.max) else {
            return nil
        }

        let durationBound = UInt64(durationFrameCount)
        let storageBound = maximumInputBufferBytesPerSlot / bytesPerInputFrame
        let boundedFrameCount = min(durationBound, storageBound)
        guard boundedFrameCount > 0 else { return nil }
        return AVAudioFrameCount(boundedFrameCount)
    }
}

nonisolated final class AudioCaptureBufferSlot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let claimed = Atomic<Bool>(false)

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw AudioCaptureFailure.bufferAllocationFailed
        }
        self.buffer = buffer
    }

    func tryAcquire() -> Bool {
        claimed.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged
    }

    func release() {
        claimed.store(false, ordering: .releasing)
    }

    func copy(from source: AVAudioPCMBuffer) -> AudioCaptureFailure? {
        guard source.format.sampleRate == buffer.format.sampleRate,
              source.format.channelCount == buffer.format.channelCount,
              source.format.commonFormat == buffer.format.commonFormat,
              source.format.isInterleaved == buffer.format.isInterleaved else {
            return .inputConfigurationChanged
        }
        guard source.frameLength <= buffer.frameCapacity else {
            return .inputBufferTooLarge
        }
        guard source.frameLength > 0 else {
            buffer.frameLength = 0
            return nil
        }

        buffer.frameLength = buffer.frameCapacity
        let sourcePointer = UnsafeMutablePointer(mutating: source.audioBufferList)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourcePointer)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            buffer.frameLength = 0
            return .inputConfigurationChanged
        }
        let bytesPerFrame = UInt64(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            buffer.frameLength = 0
            return .inputConfigurationChanged
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard sourceBuffer.mNumberChannels > 0,
                  sourceBuffer.mNumberChannels == destinationBuffer.mNumberChannels else {
                buffer.frameLength = 0
                return .inputConfigurationChanged
            }

            let channelsInBuffer = source.format.isInterleaved ? UInt64(1) : UInt64(sourceBuffer.mNumberChannels)
            let (bytesPerBufferFrame, frameByteOverflow) =
                bytesPerFrame.multipliedReportingOverflow(by: channelsInBuffer)
            let (requiredByteCount, totalByteOverflow) =
                bytesPerBufferFrame.multipliedReportingOverflow(by: UInt64(source.frameLength))
            guard !frameByteOverflow,
                  !totalByteOverflow,
                  requiredByteCount <= UInt64(Int.max) else {
                buffer.frameLength = 0
                return .inputConfigurationChanged
            }

            guard requiredByteCount <= UInt64(sourceBuffer.mDataByteSize),
                  let sourceData = sourceBuffer.mData else {
                buffer.frameLength = 0
                return .inputBufferUnavailable
            }
            guard requiredByteCount <= UInt64(destinationBuffer.mDataByteSize) else {
                buffer.frameLength = 0
                return .inputBufferTooLarge
            }
            guard let destinationData = destinationBuffer.mData else {
                buffer.frameLength = 0
                return .bufferAllocationFailed
            }
            _ = memcpy(destinationData, sourceData, Int(requiredByteCount))
        }

        buffer.frameLength = source.frameLength
        return nil
    }

    func clear() {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in buffers.indices {
            let audioBuffer = buffers[index]
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            _ = memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        buffer.frameLength = 0
    }
}

nonisolated final class AudioCaptureBufferPool: @unchecked Sendable {
    private let slots: [AudioCaptureBufferSlot]

    init(
        format: AVAudioFormat,
        slotCount: Int = AudioCaptureBounds.maximumPoolSlots,
        frameCapacity: AVAudioFrameCount? = nil
    ) throws {
        guard (1...AudioCaptureBounds.maximumPoolSlots).contains(slotCount),
              let maximumFrameCapacity = AudioCaptureBounds.maximumInputFrameCapacity(for: format) else {
            throw AudioCaptureFailure.invalidBufferPoolConfiguration
        }
        let frameCapacity = frameCapacity ?? maximumFrameCapacity
        guard frameCapacity > 0, frameCapacity <= maximumFrameCapacity else {
            throw AudioCaptureFailure.invalidBufferPoolConfiguration
        }
        slots = try (0..<slotCount).map { _ in
            try AudioCaptureBufferSlot(format: format, frameCapacity: frameCapacity)
        }
    }

    var count: Int { slots.count }

    func acquire() -> AudioCaptureBufferSlot? {
        for slot in slots where slot.tryAcquire() {
            return slot
        }
        return nil
    }
}

nonisolated private final class AudioCaptureInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let supplied = Atomic<Bool>(false)

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged {
            status.pointee = .haveData
            return buffer
        }
        status.pointee = .noDataNow
        return nil
    }
}

nonisolated final class AudioCaptureConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let inputFrameLimit: AVAudioFrameCount
    private let outputFormat: AVAudioFormat

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate.isFinite,
              (8_000...384_000).contains(inputFormat.sampleRate),
              inputFormat.channelCount > 0,
              inputFormat.channelCount <= AudioCaptureBounds.maximumInputChannels,
              inputFormat.commonFormat != .otherFormat,
              let inputFrameLimit = AudioCaptureBounds.maximumInputFrameCapacity(for: inputFormat),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCaptureBounds.sampleRate,
                channels: AudioCaptureBounds.channelCount,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureFailure.unsupportedInputFormat
        }
        converter.downmix = true
        self.converter = converter
        self.inputFormat = inputFormat
        self.inputFrameLimit = inputFrameLimit
        self.outputFormat = outputFormat
    }

    func convert(
        _ input: AVAudioPCMBuffer,
        startingAt sampleIndex: UInt64
    ) throws -> AudioCaptureChunk? {
        guard input.format.sampleRate == inputFormat.sampleRate,
              input.format.channelCount == inputFormat.channelCount,
              input.format.commonFormat == inputFormat.commonFormat,
              input.format.isInterleaved == inputFormat.isInterleaved else {
            throw AudioCaptureFailure.inputConfigurationChanged
        }
        guard input.frameLength <= inputFrameLimit else {
            throw AudioCaptureFailure.inputBufferTooLarge
        }
        guard input.frameLength > 0 else { return nil }
        let ratio = AudioCaptureBounds.sampleRate / input.format.sampleRate
        let capacityValue = ceil(Double(input.frameLength) * ratio) + 512
        guard capacityValue.isFinite,
              capacityValue > 0,
              capacityValue <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(capacityValue)
              ) else {
            throw AudioCaptureFailure.conversionFailed
        }

        let provider = AudioCaptureInputProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }
        guard conversionError == nil else { throw AudioCaptureFailure.conversionFailed }
        switch status {
        case .haveData, .inputRanDry:
            break
        case .endOfStream, .error:
            throw AudioCaptureFailure.conversionFailed
        @unknown default:
            throw AudioCaptureFailure.conversionFailed
        }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return nil }
        guard let channel = output.floatChannelData?.pointee else {
            throw AudioCaptureFailure.conversionFailed
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        return AudioCaptureChunk(
            startingSampleIndex: sampleIndex,
            sampleRate: AudioCaptureBounds.sampleRate,
            samples: samples
        )
    }

    func finish(startingAt sampleIndex: UInt64) throws -> AudioCaptureChunk? {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2_048) else {
            throw AudioCaptureFailure.conversionFailed
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard conversionError == nil, status != .error else {
            throw AudioCaptureFailure.conversionFailed
        }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return nil }
        guard let channel = output.floatChannelData?.pointee else {
            throw AudioCaptureFailure.conversionFailed
        }
        return AudioCaptureChunk(
            startingSampleIndex: sampleIndex,
            sampleRate: AudioCaptureBounds.sampleRate,
            samples: Array(UnsafeBufferPointer(start: channel, count: frameCount))
        )
    }
}

nonisolated private final class AudioCapturePipeline: @unchecked Sendable {
    private let generation: UUID
    private let pool: AudioCaptureBufferPool
    private let converter: AudioCaptureConverter
    private let continuation: AudioCaptureStream.Continuation
    private let workerQueue: DispatchQueue
    private let callbacks = DispatchGroup()
    private let accepting = Atomic<Bool>(true)
    private let terminal = Atomic<Bool>(false)
    private let onFailure: @Sendable (UUID) -> Void
    private var nextSampleIndex: UInt64 = 0

    init(
        generation: UUID,
        pool: AudioCaptureBufferPool,
        converter: AudioCaptureConverter,
        continuation: AudioCaptureStream.Continuation,
        onFailure: @escaping @Sendable (UUID) -> Void
    ) {
        self.generation = generation
        self.pool = pool
        self.converter = converter
        self.continuation = continuation
        self.onFailure = onFailure
        workerQueue = DispatchQueue(label: "com.abdulrahman.mac-utilities.audio-capture.\(generation.uuidString)")
    }

    func receive(_ input: AVAudioPCMBuffer) {
        callbacks.enter()
        defer { callbacks.leave() }
        guard accepting.load(ordering: .acquiring) else { return }
        guard let slot = pool.acquire() else {
            failFromAudioCallback(.captureOverloaded)
            return
        }
        if let failure = slot.copy(from: input) {
            slot.clear()
            slot.release()
            failFromAudioCallback(failure)
            return
        }

        workerQueue.async { [self, slot] in
            defer {
                slot.clear()
                slot.release()
            }
            guard !terminal.load(ordering: .acquiring) else { return }
            do {
                guard let chunk = try converter.convert(slot.buffer, startingAt: nextSampleIndex) else {
                    return
                }
                nextSampleIndex += UInt64(chunk.samples.count)
                guard !terminal.load(ordering: .acquiring) else { return }
                switch continuation.yield(chunk) {
                case .enqueued:
                    break
                case .dropped:
                    failOnWorker(.consumerTooSlow)
                case .terminated:
                    accepting.store(false, ordering: .releasing)
                    terminal.store(true, ordering: .releasing)
                @unknown default:
                    failOnWorker(.consumerTooSlow)
                }
            } catch {
                failOnWorker(.conversionFailed)
            }
        }
    }

    func fail(_ failure: AudioCaptureFailure) {
        accepting.store(false, ordering: .releasing)
        guard terminal.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        workerQueue.async { [self] in
            finishWithFailure(failure)
        }
    }

    func stopAccepting() {
        accepting.store(false, ordering: .releasing)
    }

    func finishAfterCallbacks() async {
        await withCheckedContinuation { done in
            callbacks.notify(queue: workerQueue) { [self] in
                guard !terminal.load(ordering: .acquiring) else {
                    done.resume()
                    return
                }
                do {
                    if let tail = try converter.finish(startingAt: nextSampleIndex) {
                        switch continuation.yield(tail) {
                        case .enqueued: break
                        case .dropped: failOnWorker(.consumerTooSlow)
                        case .terminated: terminal.store(true, ordering: .releasing)
                        @unknown default: failOnWorker(.consumerTooSlow)
                        }
                    }
                } catch {
                    failOnWorker(.conversionFailed)
                }
                if terminal.compareExchange(
                    expected: false,
                    desired: true,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    continuation.finish()
                }
                done.resume()
            }
        }
    }

    func cancelAndDrain() async {
        accepting.store(false, ordering: .releasing)
        terminal.store(true, ordering: .releasing)
        await withCheckedContinuation { done in
            callbacks.notify(queue: workerQueue) { [self] in
                continuation.finish()
                done.resume()
            }
        }
    }

    private func failFromAudioCallback(_ failure: AudioCaptureFailure) {
        accepting.store(false, ordering: .releasing)
        guard terminal.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        workerQueue.async { [self] in
            finishWithFailure(failure)
        }
    }

    private func failOnWorker(_ failure: AudioCaptureFailure) {
        accepting.store(false, ordering: .releasing)
        guard terminal.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        finishWithFailure(failure)
    }

    private func finishWithFailure(_ failure: AudioCaptureFailure) {
        continuation.finish(throwing: failure)
        onFailure(generation)
    }
}

@MainActor
final class AudioCaptureStopGate {
    private var task: Task<Void, Never>?

    var isStopping: Bool { task != nil }

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let current = Task { @MainActor in await operation() }
        task = current
        await current.value
        task = nil
    }
}

@MainActor
final class AudioCaptureAdapter: AudioCapturing {
    private struct Session {
        let id: UUID
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let pipeline: AudioCapturePipeline
        let engineObserver: NSObjectProtocol
        let sleepObserver: NSObjectProtocol
    }

    private var session: Session?
    private let stopGate = AudioCaptureStopGate()

    var isCapturing: Bool { session != nil && !stopGate.isStopping }

    func start() throws -> AudioCaptureStream {
        guard session == nil, !stopGate.isStopping else { throw AudioCaptureFailure.alreadyCapturing }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            throw AudioCaptureFailure.microphonePermissionUndetermined
        case .denied:
            throw AudioCaptureFailure.microphonePermissionDenied
        @unknown default:
            throw AudioCaptureFailure.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
            throw AudioCaptureFailure.inputUnavailable
        }

        let pool: AudioCaptureBufferPool
        let converter: AudioCaptureConverter
        do {
            pool = try AudioCaptureBufferPool(format: inputFormat)
            converter = try AudioCaptureConverter(inputFormat: inputFormat)
        } catch let failure as AudioCaptureFailure {
            throw failure
        } catch {
            throw AudioCaptureFailure.bufferAllocationFailed
        }

        let generation = UUID()
        let (stream, continuation) = AudioCaptureStream.makeStream(
            bufferingPolicy: .bufferingOldest(AudioCaptureBounds.streamChunkCapacity)
        )
        let pipeline = AudioCapturePipeline(
            generation: generation,
            pool: pool,
            converter: converter,
            continuation: continuation
        ) { [weak self] sessionID in
            Task { @MainActor [weak self] in
                await self?.stop(sessionID: sessionID, cancel: true)
            }
        }

        let engineObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: "AVAudioEngineConfigurationChangeNotification"),
            object: engine,
            queue: nil
        ) { [weak engine, weak pipeline] _ in
            engine?.stop()
            pipeline?.fail(.inputConfigurationChanged)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak engine, weak pipeline] _ in
            engine?.stop()
            pipeline?.fail(.systemWillSleep)
        }

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self] in
                await self?.stop(sessionID: generation, cancel: true)
            }
        }

        session = Session(
            id: generation,
            engine: engine,
            inputNode: inputNode,
            pipeline: pipeline,
            engineObserver: engineObserver,
            sleepObserver: sleepObserver
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: AudioCaptureBounds.tapBufferSize,
            format: inputFormat
        ) { [pipeline] buffer, _ in
            pipeline.receive(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            removeObservers(engineObserver: engineObserver, sleepObserver: sleepObserver)
            session = nil
            pipeline.fail(.engineStartFailed)
            throw AudioCaptureFailure.engineStartFailed
        }
        return stream
    }

    func stop() async {
        await stop(sessionID: nil, cancel: false)
    }

    func cancel() async {
        await stop(sessionID: nil, cancel: true)
    }

    private func stop(sessionID: UUID?, cancel: Bool) async {
        guard let current = session,
              sessionID == nil || sessionID == current.id else { return }
        await stopGate.run {
            current.pipeline.stopAccepting()
            current.engine.stop()
            current.inputNode.removeTap(onBus: 0)
            self.removeObservers(engineObserver: current.engineObserver, sleepObserver: current.sleepObserver)
            if cancel {
                await current.pipeline.cancelAndDrain()
            } else {
                await current.pipeline.finishAfterCallbacks()
            }
            if self.session?.id == current.id { self.session = nil }
        }
    }

    private func removeObservers(engineObserver: NSObjectProtocol, sleepObserver: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(engineObserver)
        NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
    }
}
