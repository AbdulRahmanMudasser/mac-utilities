import AVFoundation
import Testing
@testable import Mac_Utilities

struct AudioCaptureAdapterTests {
    @Test @MainActor
    func concurrentStopRequestsJoinTheSameCleanup() async {
        let gate = AudioCaptureStopGate()
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        var secondReturned = false
        let first = Task { @MainActor in
            await gate.run {
                calls += 1
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        let second = Task { @MainActor in
            await gate.run { calls += 1 }
            secondReturned = true
        }
        await Task.yield()
        #expect(gate.isStopping)
        #expect(!secondReturned)
        continuation?.resume()
        await first.value
        await second.value
        #expect(calls == 1)
        #expect(secondReturned)
        #expect(!gate.isStopping)
        await gate.run { calls += 1 }
        #expect(calls == 2)
    }

    @Test
    func capturePoolIsBoundedAndReusesReleasedSlots() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pool = try AudioCaptureBufferPool(format: format, slotCount: 2, frameCapacity: 128)
        let first = try #require(pool.acquire())
        let second = try #require(pool.acquire())
        #expect(pool.acquire() == nil)
        first.release()
        let reused = try #require(pool.acquire())
        reused.release()
        second.release()
    }

    @Test
    func inputFrameBoundAccountsForDurationAndPerSlotStorage() throws {
        let observedFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let observedFrameLimit = try #require(
            AudioCaptureBounds.maximumInputFrameCapacity(for: observedFormat)
        )
        #expect(observedFrameLimit == 12_000)

        let highRateFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 96_000,
                channels: 2,
                interleaved: false
            )
        )
        let highRateFrameLimit = try #require(
            AudioCaptureBounds.maximumInputFrameCapacity(for: highRateFormat)
        )
        let bytesPerInputFrame = UInt64(highRateFormat.streamDescription.pointee.mBytesPerFrame)
            * UInt64(highRateFormat.channelCount)
        #expect(highRateFrameLimit == 24_000)
        #expect(UInt64(highRateFrameLimit) * bytesPerInputFrame <= AudioCaptureBounds.maximumInputBufferBytesPerSlot)
    }

    @Test
    func capturePoolCopiesMoreThan4096FramesUsingFrameLength() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pool = try AudioCaptureBufferPool(format: format, slotCount: 1)
        let slot = try #require(pool.acquire())
        let frameLength: AVAudioFrameCount = 8_192
        let sourceCapacity: AVAudioFrameCount = 16_384
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sourceCapacity))
        input.frameLength = frameLength

        let inputChannels = try #require(input.floatChannelData)
        inputChannels[0][0] = 0.25
        inputChannels[0][Int(frameLength) - 1] = 0.875

        // Model a tap buffer whose allocated byte size exceeds the pool slot even
        // though its valid frameLength fits. Copy only those valid frames.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        sourceBuffers[0].mDataByteSize = UInt32(Int(sourceCapacity) * MemoryLayout<Float>.size)
        slot.buffer.frameLength = slot.buffer.frameCapacity
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(slot.buffer.mutableAudioBufferList)
        #expect(sourceBuffers[0].mDataByteSize > destinationBuffers[0].mDataByteSize)
        #expect(slot.buffer.frameCapacity >= frameLength)

        #expect(slot.copy(from: input) == nil)
        #expect(slot.buffer.frameLength == frameLength)
        let copiedChannels = try #require(slot.buffer.floatChannelData)
        #expect(copiedChannels[0][0] == 0.25)
        #expect(copiedChannels[0][Int(frameLength) - 1] == 0.875)
        slot.clear()
        slot.release()
    }

    @Test
    func capturePoolAndConverterRejectFramesBeyondTheBound() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let maximumFrameCount = try #require(AudioCaptureBounds.maximumInputFrameCapacity(for: format))
        let oversizedFrameCount = maximumFrameCount + 1
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: oversizedFrameCount))
        input.frameLength = oversizedFrameCount

        let pool = try AudioCaptureBufferPool(format: format, slotCount: 1)
        let slot = try #require(pool.acquire())
        #expect(slot.copy(from: input) == .inputBufferTooLarge)
        #expect(slot.buffer.frameLength == 0)

        let converter = try AudioCaptureConverter(inputFormat: format)
        var conversionFailure: AudioCaptureFailure?
        do {
            _ = try converter.convert(input, startingAt: 0)
        } catch {
            conversionFailure = error as? AudioCaptureFailure
        }
        #expect(conversionFailure == .inputBufferTooLarge)
        slot.release()
    }

    @Test
    func converterProducesMono16kHzForStereoInput() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        let channels = try #require(input.floatChannelData)
        for index in 0..<4_800 {
            channels[0][index] = 0.25
            channels[1][index] = 0.25
        }
        let converter = try AudioCaptureConverter(inputFormat: format)
        let converted = try converter.convert(input, startingAt: 42)
        let chunk = try #require(converted)
        let tail = try converter.finish(startingAt: 42 + UInt64(chunk.samples.count))
        #expect(chunk.startingSampleIndex == 42)
        #expect(chunk.sampleRate == 16_000)
        #expect(chunk.channelCount == 1)
        #expect((1_590...1_610).contains(chunk.samples.count + (tail?.samples.count ?? 0)))
        #expect(tail?.startingSampleIndex == 42 + UInt64(chunk.samples.count))
        let samplesAreFinite = chunk.samples.allSatisfy { $0.isFinite }
        #expect(samplesAreFinite)
    }

    @Test
    func converterKeepsSampleAccountingAcrossMultipleBuffersAndStop() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try AudioCaptureConverter(inputFormat: format)
        var nextIndex: UInt64 = 0
        for _ in 0..<4 {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            input.frameLength = 4_800
            let channels = try #require(input.floatChannelData)
            for index in 0..<4_800 { channels[0][index] = 0.125 }
            if let chunk = try converter.convert(input, startingAt: nextIndex) {
                #expect(chunk.startingSampleIndex == nextIndex)
                nextIndex += UInt64(chunk.samples.count)
            }
        }
        if let tail = try converter.finish(startingAt: nextIndex) {
            #expect(tail.startingSampleIndex == nextIndex)
            nextIndex += UInt64(tail.samples.count)
        }
        #expect((6_390...6_410).contains(nextIndex))
    }

    @Test
    func converterConvertsVariableTapBufferAbove4096AndFlushesResamplerTail() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        input.frameLength = 8_192
        let channels = try #require(input.floatChannelData)
        for index in 0..<8_192 { channels[0][index] = 0.125 }

        let converter = try AudioCaptureConverter(inputFormat: format)
        let converted = try converter.convert(input, startingAt: 73)
        let chunk = try #require(converted)
        let nextIndex = 73 + UInt64(chunk.samples.count)
        let tail = try converter.finish(startingAt: nextIndex)
        let totalSampleCount = chunk.samples.count + (tail?.samples.count ?? 0)

        #expect(chunk.startingSampleIndex == 73)
        #expect(chunk.sampleRate == 16_000)
        #expect((2_720...2_740).contains(totalSampleCount))
        #expect(tail?.startingSampleIndex == nextIndex)
        let samplesAreFinite = chunk.samples.allSatisfy { $0.isFinite }
        #expect(samplesAreFinite)
    }
}
