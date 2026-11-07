import Foundation

nonisolated struct AudioCaptureChunk: Equatable, Sendable {
    let startingSampleIndex: UInt64
    let sampleRate: Double
    let samples: [Float]

    var channelCount: Int { 1 }
}

typealias AudioCaptureStream = AsyncThrowingStream<AudioCaptureChunk, any Error>
