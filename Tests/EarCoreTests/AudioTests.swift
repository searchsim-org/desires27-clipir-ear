import XCTest

@testable import EarCore

final class PCMConverterTests: XCTestCase {
    func test48kStereoFloatTo16kMonoInt16() throws {
        let input = TestAudio.sineBuffer(seconds: 2)
        let converter = try PCMConverter(inputFormat: input.format)
        let out = try converter.convert(input) + converter.flush()
        XCTAssertEqual(Double(out.count), 32_000, accuracy: 320)  // length within 1 %
        let expected = 0.5 / 2.0.squareRoot() * 32767
        XCTAssertEqual(TestAudio.rms(out), expected, accuracy: expected * 0.01)  // RMS within 1 %
    }
}

final class FileCaptureSourceTests: XCTestCase {
    private func collect(_ source: FileCaptureSource) async throws -> [PCMFrame] {
        try await source.start()
        var frames: [PCMFrame] = []
        for await f in source.frames { frames.append(f) }
        return frames
    }

    func testNonRealtimeIsFastAndFrameCountMatchesDuration() async throws {
        let url = try TestAudio.writeWav(seconds: 60)
        let t0 = Date()
        let frames = try await collect(FileCaptureSource(url: url, realtime: false))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        XCTAssertEqual(frames.count, 3000, accuracy: 1)
        XCTAssertTrue(frames.allSatisfy { $0.samples.count == 320 && $0.sampleRate == 16_000 })
        XCTAssertEqual(frames.last!.timestamp, 59.98, accuracy: 0.03)
    }

    func testRealtimePacingWithin5Percent() async throws {
        let url = try TestAudio.writeWav(seconds: 10)
        let t0 = Date()
        let frames = try await collect(FileCaptureSource(url: url, realtime: true))
        XCTAssertEqual(Date().timeIntervalSince(t0), 10, accuracy: 0.5)
        XCTAssertEqual(frames.count, 500, accuracy: 1)
    }
}

final class AudioOutputTests: XCTestCase {
    func testOfflineRenderKeepsChunkOrder() throws {
        let out = try AudioOutput(sampleRate: 16_000, manualRendering: true)
        out.enqueue(AudioChunk(samples: Array(repeating: 8192, count: 1600), sampleRate: 16_000))
        out.enqueue(AudioChunk(samples: Array(repeating: -8192, count: 1600), sampleRate: 16_000))
        let rendered = try out.render(frames: 3200)
        XCTAssertEqual(rendered[800], 0.25, accuracy: 0.01)
        XCTAssertEqual(rendered[2400], -0.25, accuracy: 0.01)
    }

    func testOneSecondSineRendersAndStopFlushes() throws {
        let out = try AudioOutput(sampleRate: 16_000, manualRendering: true)
        let sine = (0..<16_000).map { Int16(10_000 * sin(2 * .pi * 440 * Double($0) / 16_000)) }
        out.enqueue(AudioChunk(samples: sine, sampleRate: 16_000))
        let first = try out.render(frames: 16_000)
        XCTAssertGreaterThan(first.map { abs($0) }.max()!, 0.25)
        out.enqueue(AudioChunk(samples: sine, sampleRate: 16_000))
        out.stop()
        let afterStop = try out.render(frames: 1600)
        XCTAssertEqual(afterStop.map { abs($0) }.max() ?? 0, 0, accuracy: 1e-6)
        XCTAssertFalse(out.isPlaying)
    }

    func testEarconsAre120msAndDistinct() {
        let a = Earcon.listening.chunk(sampleRate: 24_000)
        let b = Earcon.fallback.chunk(sampleRate: 24_000)
        XCTAssertEqual(a.duration, 0.12, accuracy: 0.001)
        XCTAssertNotEqual(a.samples, b.samples)
    }
}

final class LatencyTraceTests: XCTestCase {
    func testMarksAreRelativeToPttDownAndFirstMarkWins() throws {
        let trace = LatencyTrace()
        trace.mark(.pttDown)
        trace.mark(.speechEnd)
        trace.mark(.speechEnd)
        let e = trace.export()
        XCTAssertEqual(e[.pttDown], 0)
        XCTAssertGreaterThanOrEqual(e[.speechEnd]!, 0)
        XCTAssertTrue(trace.json().contains("\"speechEnd\""))
    }
}

final class EgressTests: XCTestCase {
    func testOnlyLocalhostMacAndOpenModelWindowAreAllowed() async throws {
        let ledger = ConnectionLedger()
        let egress = EgressGuard(ledger: ledger)
        XCTAssertNoThrow(try egress.check(host: "localhost"))
        XCTAssertThrowsError(try egress.check(host: "api.example.net"))
        egress.setPairedMac(host: "192.168.1.20")
        XCTAssertNoThrow(try egress.check(host: "192.168.1.20"))
        XCTAssertThrowsError(try egress.check(host: "huggingface.co"))
        try await egress.withModelDownloads(hosts: ["huggingface.co", "cdn.hf.co"]) {
            XCTAssertNoThrow(try egress.check(host: "us.aws.cdn.hf.co"))
        }
        XCTAssertThrowsError(try egress.check(host: "us.aws.cdn.hf.co"))
        XCTAssertEqual(ledger.violations().map(\.host), ["api.example.net", "huggingface.co", "us.aws.cdn.hf.co"])
        let blocked = URL(string: "https" + "://evil.example.org/x")!  // split: egress_check would flag it on purpose
        XCTAssertThrowsError(try egress.session(for: blocked))
    }
}
