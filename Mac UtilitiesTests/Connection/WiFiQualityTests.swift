import Foundation
import Testing
@testable import Mac_Utilities

actor ImmediateWiFiQualityReader: WiFiQualityReading {
    private let snapshots: [WiFiQualitySnapshot]
    private var reads = 0

    init(_ snapshots: [WiFiQualitySnapshot]) {
        self.snapshots = snapshots
    }

    func read() async -> WiFiQualitySnapshot {
        let index = reads
        reads += 1
        return snapshots[min(index, snapshots.count - 1)]
    }

    func readCount() -> Int { reads }
}

actor DeferredWiFiQualityReader: WiFiQualityReading {
    private var reads = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var pending: [CheckedContinuation<WiFiQualitySnapshot, Never>] = []

    func read() async -> WiFiQualitySnapshot {
        reads += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        let snapshot = await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
        activeReads -= 1
        return snapshot
    }

    func readCount() -> Int { reads }
    func maximumConcurrentReads() -> Int { maximumActiveReads }

    func resolveNext(with snapshot: WiFiQualitySnapshot) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: snapshot)
    }
}

func sampleWiFiSnapshot(
    at date: Date = Date(timeIntervalSince1970: 1_797_000_000),
    interfaceName: String? = "en0",
    signal: Int? = -48,
    noise: Int? = -91,
    channel: Int? = 36,
    band: WiFiChannelBand = .fiveGHz,
    width: WiFiChannelWidth = .mhz80,
    rate: Double? = 866.7
) -> WiFiQualitySnapshot {
    WiFiQualitySnapshot(sampledAt: date, interfaceName: interfaceName, signalDBm: signal,
        noiseDBm: noise, channelNumber: channel, channelBand: band, channelWidth: width,
        transmitRateMbps: rate)
}

@MainActor
func waitForWiFiReads(_ count: Int, from reader: ImmediateWiFiQualityReader) async {
    for _ in 0..<2_000 {
        if await reader.readCount() >= count { return }
        await Task.yield()
    }
    #expect(await reader.readCount() >= count)
}

@MainActor
func waitForWiFiReads(_ count: Int, from reader: DeferredWiFiQualityReader) async {
    for _ in 0..<2_000 {
        if await reader.readCount() >= count { return }
        await Task.yield()
    }
    #expect(await reader.readCount() >= count)
}

@MainActor
func waitForWiFiSnapshot(_ expected: WiFiQualitySnapshot, from monitor: WiFiQualityMonitor) async {
    for _ in 0..<2_000 where monitor.snapshot != expected {
        await Task.yield()
    }
    #expect(monitor.snapshot == expected)
}

@Suite(.serialized)
@MainActor
struct WiFiQualityTests {
    @Test func snapshotsRejectSentinelsAndKeepValidPartialReadings() {
        let partial = WiFiQualitySnapshot(signalDBm: 0, noiseDBm: -89, channelNumber: nil,
            channelBand: .notAvailable, channelWidth: .notAvailable, transmitRateMbps: 0)

        #expect(partial.availability == .available)
        #expect(partial.signalText == "Not Available")
        #expect(partial.noiseText == "-89 dBm")
        #expect(partial.channelText == "Not Available")
        #expect(partial.transmitRateText == "Not Available")
        #expect(partial.hasAnyReading)

        let partialWithUnavailableState = WiFiQualitySnapshot(
            noiseDBm: -89, availability: .noDefaultInterface)
        #expect(partialWithUnavailableState.hasAnyReading)
    }

    @Test func emptySentinelReadingsBecomeUnavailable() {
        let snapshot = WiFiQualitySnapshot(signalDBm: 0, noiseDBm: 0, channelNumber: 0,
            transmitRateMbps: .infinity)

        #expect(snapshot.availability == .unavailable)
        #expect(snapshot.availability.statusMessage == "Wi-Fi Readings Unavailable")
        #expect(snapshot.signalDBm == nil)
        #expect(snapshot.noiseDBm == nil)
        #expect(snapshot.channelNumber == nil)
        #expect(snapshot.transmitRateMbps == nil)
        #expect(!snapshot.hasAnyReading)
    }

    @Test func channelFormattingPreservesUnknownBandAndWidth() {
        let snapshot = sampleWiFiSnapshot(channel: 149, band: .unknown, width: .unknown)

        #expect(snapshot.channelText == "149 · Unknown Band · Unknown Width")
        #expect(snapshot.transmitRateText == "866.7 Mbps")
    }

    @Test func interfaceDiscoveryStatesRemainDistinct() {
        #expect(WiFiQualitySnapshot(availability: .discoveryUnavailable).availability.statusMessage == "Wi-Fi Readings Unavailable")
        #expect(WiFiQualitySnapshot(availability: .noInterfaces).availability.statusMessage == "No Wi-Fi Interface Available")
        #expect(WiFiQualitySnapshot(availability: .noDefaultInterface).availability.statusMessage == "No Default Wi-Fi Interface")
    }

    @Test func monitorRefreshesImmediatelyRepeatsWhileVisibleAndStopsWhenHidden() async throws {
        let first = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_001))
        let second = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_002), signal: -52)
        let reader = ImmediateWiFiQualityReader([first, second])
        let monitor = WiFiQualityMonitor(reader: reader, refreshInterval: .milliseconds(10))
        defer { monitor.shutdown() }

        monitor.setVisible(true)
        await waitForWiFiReads(1, from: reader)
        await waitForWiFiSnapshot(first, from: monitor)
        #expect(monitor.snapshot == first)
        await waitForWiFiReads(2, from: reader)
        await waitForWiFiSnapshot(second, from: monitor)
        #expect(monitor.snapshot == second)

        monitor.setVisible(false)
        let stoppedAt = await reader.readCount()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.readCount() == stoppedAt)
        #expect(!monitor.isVisible)
    }

    @Test func wakeForcesFreshSnapshotAndHiddenWakeStaysStopped() async {
        let first = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_011))
        let fresh = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_012), signal: -55)
        let reader = ImmediateWiFiQualityReader([first, fresh])
        let monitor = WiFiQualityMonitor(reader: reader, refreshInterval: .seconds(30))
        defer { monitor.shutdown() }

        monitor.setVisible(true)
        await waitForWiFiReads(1, from: reader)
        await waitForWiFiSnapshot(first, from: monitor)
        #expect(monitor.snapshot == first)
        monitor.refreshAfterWake(isVisible: true)
        #expect(monitor.snapshot == nil)
        await waitForWiFiReads(2, from: reader)
        await waitForWiFiSnapshot(fresh, from: monitor)
        #expect(monitor.snapshot == fresh)

        monitor.refreshAfterWake(isVisible: false)
        let stoppedAt = await reader.readCount()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await reader.readCount() == stoppedAt)
    }

    @Test func staleReadAfterHideCannotPublishAndRefreshesAreCoalesced() async {
        let reader = DeferredWiFiQualityReader()
        let monitor = WiFiQualityMonitor(reader: reader, refreshInterval: .seconds(30))
        defer { monitor.shutdown() }

        monitor.setVisible(true)
        await waitForWiFiReads(1, from: reader)
        monitor.setVisible(false)
        monitor.setVisible(true)
        #expect(await reader.readCount() == 1)

        await reader.resolveNext(with: sampleWiFiSnapshot(interfaceName: "en0", signal: -42))
        await waitForWiFiReads(2, from: reader)
        #expect(monitor.snapshot == nil)
        #expect(await reader.maximumConcurrentReads() == 1)

        let fresh = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_020), interfaceName: "en1", signal: -61)
        await reader.resolveNext(with: fresh)
        await waitForWiFiSnapshot(fresh, from: monitor)
        #expect(monitor.snapshot == fresh)
        monitor.shutdown()
    }

    @Test func wakeAndShutdownRejectLateInFlightResults() async {
        let reader = DeferredWiFiQualityReader()
        let monitor = WiFiQualityMonitor(reader: reader, refreshInterval: .seconds(30))

        monitor.setVisible(true)
        await waitForWiFiReads(1, from: reader)
        monitor.refreshAfterWake(isVisible: true)
        await reader.resolveNext(with: sampleWiFiSnapshot(signal: -41))
        await waitForWiFiReads(2, from: reader)
        #expect(monitor.snapshot == nil)

        let fresh = sampleWiFiSnapshot(at: Date(timeIntervalSince1970: 1_797_000_030), signal: -57)
        await reader.resolveNext(with: fresh)
        await waitForWiFiSnapshot(fresh, from: monitor)
        #expect(monitor.snapshot == fresh)

        monitor.refreshAfterWake(isVisible: true)
        await waitForWiFiReads(3, from: reader)
        monitor.shutdown()
        await reader.resolveNext(with: sampleWiFiSnapshot(signal: -35))
        for _ in 0..<2_000 { await Task.yield() }
        #expect(monitor.snapshot == nil)
        #expect(!monitor.isVisible)
    }

    @Test func unavailableRefreshReplacesPriorValues() async {
        let connected = sampleWiFiSnapshot()
        let unavailable = WiFiQualitySnapshot(
            sampledAt: Date(timeIntervalSince1970: 1_797_000_040),
            availability: .noDefaultInterface
        )
        let reader = ImmediateWiFiQualityReader([connected, unavailable])
        let monitor = WiFiQualityMonitor(reader: reader, refreshInterval: .milliseconds(10))
        defer { monitor.shutdown() }

        monitor.setVisible(true)
        await waitForWiFiReads(1, from: reader)
        await waitForWiFiSnapshot(connected, from: monitor)
        await waitForWiFiReads(2, from: reader)
        await waitForWiFiSnapshot(unavailable, from: monitor)

        #expect(monitor.snapshot?.availability == .noDefaultInterface)
        #expect(monitor.snapshot?.signalDBm == nil)
        #expect(monitor.snapshot?.transmitRateMbps == nil)
    }
}
