import Foundation
import Testing
@testable import Mac_Utilities

struct SpeechSegmentsTests {
    @Test
    func sampleRangeExposesHalfOpenSamplesAndDerivedTimeRange() throws {
        let range = try SpeechAudioSampleRange(
            startSample: 16_000,
            endSample: 48_000,
            sampleRate: 16_000
        )

        #expect(range.sampleCount == 32_000)
        #expect(range.startTime == 1)
        #expect(range.endTime == 3)
        #expect(range.duration == 2)
        #expect(range.timeRange == 1.0..<3.0)
    }

    @Test
    func rejectsInvalidSampleRates() {
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechAudioSampleRange(startSample: 0, endSample: 1, sampleRate: 0)
        }
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechAudioSampleRange(startSample: 0, endSample: 1, sampleRate: -16_000)
        }
    }

    @Test
    func rejectsNegativeEmptyAndReversedSampleRanges() {
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechAudioSampleRange(startSample: -1, endSample: 1, sampleRate: 16_000)
        }
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechAudioSampleRange(startSample: 4, endSample: 4, sampleRate: 16_000)
        }
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechAudioSampleRange(startSample: 5, endSample: 4, sampleRate: 16_000)
        }
    }

    @Test
    func sortsOutOfOrderWindowResultsIntoMonotonicAudioOrder() throws {
        let first = try segment(0, 16_000, text: "first")
        let second = try segment(16_000, 32_000, text: "second")
        let third = try segment(48_000, 64_000, text: "third")

        let merged = try SpeechFinalizedSegmentMerger.merge([[third, first], [second]])

        #expect(merged == [first, second, third])
        for (earlier, later) in zip(merged, merged.dropFirst()) {
            #expect(earlier.audioRange.startSample <= later.audioRange.startSample)
            #expect(earlier.audioRange.endSample <= later.audioRange.startSample)
        }
    }

    @Test
    func collapsesExactDuplicatesAcrossOverlappingInferenceWindows() throws {
        let first = try segment(0, 16_000, text: "first")
        let shared = try segment(16_000, 32_000, text: "shared")
        let last = try segment(32_000, 48_000, text: "last")

        let merged = try SpeechFinalizedSegmentMerger.merge([
            [first, shared],
            [shared, last]
        ])

        #expect(merged == [first, shared, last])
    }

    @Test
    func rejectsSameRangeWithDifferentText() throws {
        let first = try segment(0, 16_000, text: "recognized one")
        let conflicting = try segment(0, 16_000, text: "recognized two")

        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechFinalizedSegmentMerger.merge([[first], [conflicting]])
        }
    }

    @Test
    func rejectsPartialAndNestedOverlapsInsteadOfTrimmingEitherSegment() throws {
        let first = try segment(0, 20_000, text: "keep all of this")
        let partial = try segment(19_000, 30_000, text: "keep all of that")
        let nested = try segment(5_000, 10_000, text: "nested speech")

        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechFinalizedSegmentMerger.merge([[first], [partial]])
        }
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechFinalizedSegmentMerger.merge([[first, nested]])
        }
    }

    @Test
    func textWithDifferentUtf8BytesIsNotTreatedAsAnExactDuplicate() throws {
        let composed = String("\u{00E9}")
        let decomposed = String("e\u{0301}")
        let first = try segment(0, 16_000, text: composed)
        let second = try segment(0, 16_000, text: decomposed)

        #expect(first != second)
        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechFinalizedSegmentMerger.merge([[first], [second]])
        }
    }

    @Test
    func rejectsMixedSampleRatesBecauseTheirIndicesAreNotComparable() throws {
        let first = try segment(0, 16_000, text: "first", sampleRate: 16_000)
        let second = try segment(16_000, 32_000, text: "second", sampleRate: 48_000)

        #expect(throws: SpeechSegmentMergeError.self) {
            try SpeechFinalizedSegmentMerger.merge([[first], [second]])
        }
    }

    @Test
    func preservesTextAndAllowsAdjacentRangesAndGaps() throws {
        let text = "  transcript as supplied\n"
        let first = try segment(0, 1, text: text)
        let adjacent = try segment(1, 2, text: "adjacent")
        let afterGap = try segment(10, 11, text: "after gap")

        let merged = try SpeechFinalizedSegmentMerger.merge([[first, adjacent, afterGap]])

        #expect(merged.map(\.text) == [text, "adjacent", "after gap"])
        #expect(merged[0].text.utf8.elementsEqual(text.utf8))
    }

    private func segment(
        _ startSample: Int64,
        _ endSample: Int64,
        text: String,
        sampleRate: Int = 16_000
    ) throws -> SpeechFinalizedSegment {
        SpeechFinalizedSegment(
            audioRange: try SpeechAudioSampleRange(
                startSample: startSample,
                endSample: endSample,
                sampleRate: sampleRate
            ),
            text: text
        )
    }
}
