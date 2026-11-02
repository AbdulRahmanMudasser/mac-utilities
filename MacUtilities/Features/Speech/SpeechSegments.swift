import Foundation

nonisolated struct SpeechAudioSampleRange: Equatable, Hashable, Sendable {
    let startSample: Int64
    let endSample: Int64
    let sampleRate: Int

    init(startSample: Int64, endSample: Int64, sampleRate: Int) throws {
        guard sampleRate > 0 else {
            throw SpeechSegmentMergeError.invalidSampleRate
        }
        guard startSample >= 0, endSample > startSample else {
            throw SpeechSegmentMergeError.invalidSampleRange
        }

        self.startSample = startSample
        self.endSample = endSample
        self.sampleRate = sampleRate
    }

    var sampleCount: Int64 {
        endSample - startSample
    }

    var startTime: TimeInterval {
        Double(startSample) / Double(sampleRate)
    }

    var endTime: TimeInterval {
        Double(endSample) / Double(sampleRate)
    }

    var duration: TimeInterval {
        Double(sampleCount) / Double(sampleRate)
    }

    var timeRange: Range<TimeInterval> {
        startTime..<endTime
    }
}

nonisolated struct SpeechFinalizedSegment: Equatable, Sendable {
    let audioRange: SpeechAudioSampleRange
    let text: String

    init(audioRange: SpeechAudioSampleRange, text: String) {
        self.audioRange = audioRange
        self.text = text
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.audioRange == rhs.audioRange && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

nonisolated enum SpeechSegmentMergeError: Error, Equatable, Sendable {
    case invalidSampleRate
    case invalidSampleRange
    case incompatibleSampleRates
    case ambiguousOverlap(
        existingRange: SpeechAudioSampleRange,
        incomingRange: SpeechAudioSampleRange
    )
}

nonisolated enum SpeechFinalizedSegmentMerger {
    static func merge(
        _ segmentsByWindow: [[SpeechFinalizedSegment]]
    ) throws -> [SpeechFinalizedSegment] {
        let candidates = segmentsByWindow.flatMap { $0 }
        guard let sampleRate = candidates.first?.audioRange.sampleRate else {
            return []
        }
        guard candidates.allSatisfy({ $0.audioRange.sampleRate == sampleRate }) else {
            throw SpeechSegmentMergeError.incompatibleSampleRates
        }

        let orderedCandidates = candidates.sorted(by: precedes)
        var merged: [SpeechFinalizedSegment] = []
        merged.reserveCapacity(orderedCandidates.count)

        for candidate in orderedCandidates {
            guard let previous = merged.last else {
                merged.append(candidate)
                continue
            }

            if previous == candidate {
                continue
            }

            if candidate.audioRange.startSample < previous.audioRange.endSample {
                throw SpeechSegmentMergeError.ambiguousOverlap(
                    existingRange: previous.audioRange,
                    incomingRange: candidate.audioRange
                )
            }

            merged.append(candidate)
        }

        return merged
    }

    private static func precedes(
        _ lhs: SpeechFinalizedSegment,
        _ rhs: SpeechFinalizedSegment
    ) -> Bool {
        if lhs.audioRange.startSample != rhs.audioRange.startSample {
            return lhs.audioRange.startSample < rhs.audioRange.startSample
        }
        if lhs.audioRange.endSample != rhs.audioRange.endSample {
            return lhs.audioRange.endSample < rhs.audioRange.endSample
        }
        return lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8)
    }
}
