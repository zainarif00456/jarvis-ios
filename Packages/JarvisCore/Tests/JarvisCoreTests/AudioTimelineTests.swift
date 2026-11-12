import XCTest
@testable import JarvisCore

final class AudioTests: XCTestCase {
    func testInt16RoundTripLittleEndian() {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 12345]
        let d = PCM.data(from: samples)
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual(Array(d.prefix(4)), [0, 0, 1, 0])
        XCTAssertEqual(d[4], 0xFF); XCTAssertEqual(d[5], 0xFF)    // -1
        XCTAssertEqual(PCM.int16(from: d), samples)
        XCTAssertEqual(PCM.int16(from: Data([1, 2, 3])), [0x0201], "odd trailing byte ignored")
    }
    func testFloatConversionClamps() {
        XCTAssertEqual(PCM.int16(fromFloats: [0, 1.0, -1.0, 2.0, -2.0, 0.5]), [0, 32767, -32768, 32767, -32768, 16384])
        XCTAssertEqual(PCM.floats(from: [16384, -32768])[0], 0.5, accuracy: 1e-6)
    }
    func testRms() {
        XCTAssertEqual(PCM.rms([Int16](repeating: 0, count: 100)), 0)
        XCTAssertEqual(PCM.rms([Int16](repeating: 16384, count: 100)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(PCM.rms([Int16]()), 0)
    }
    func testFrameChunkerGivesExact40msFrames() {
        var c = FrameChunker()
        XCTAssertEqual(c.push(Data(count: 1000)).count, 0)
        let frames = c.push(Data(count: 1000))      // 2000 bytes buffered: one frame (1280), 720 left
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames[0].count, 1280); XCTAssertEqual(c.buffered, 720)
        let more = c.push(Data(count: 2560 + 560))  // 720 + 3120 = 3840 = 3 frames exactly
        XCTAssertEqual(more.count, 3); XCTAssertEqual(c.buffered, 0)
        XCTAssertTrue(more.allSatisfy { $0.count == PCM.frameBytes })
        XCTAssertEqual(PCM.frameSamples * 2, PCM.frameBytes)
        XCTAssertEqual(Double(PCM.frameSamples) / Double(PCM.micRate), 0.04, accuracy: 1e-9)
    }
    func testChunkerKeepsOrder() {
        var c = FrameChunker(frameBytes: 4)
        let out = c.push(Data([1, 2, 3, 4, 5, 6])) + c.push(Data([7, 8, 9]))
        XCTAssertEqual(out, [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])])
        XCTAssertEqual(c.buffered, 1)
    }
    func testSampleAlignerSurvivesOddChunks() {
        var a = SampleAligner()
        let all = PCM.data(from: [100, -200, 300, -400, 500])
        var got: [Int16] = []
        for chunk in [all.prefix(3), all.dropFirst(3).prefix(4), all.dropFirst(7)] { got += a.push(Data(chunk)) }
        XCTAssertEqual(got, [100, -200, 300, -400, 500])
    }
    func testTtsSeconds() { XCTAssertEqual(PCM.ttsSeconds(bytes: 48_000), 1.0, accuracy: 1e-9) }

    func testDuckDetectorNeedsSustainedLoudSpeechWhilePlaying() {
        var d = DuckDetector()
        for _ in 0..<10 { XCTAssertFalse(d.micFrame(rms: 0.2, muted: false, playing: false), "not while nothing plays") }
        d = DuckDetector()
        var fired = 0
        for i in 0..<5 { if d.micFrame(rms: 0.2, muted: false, playing: true) { fired = i + 1 } }
        XCTAssertEqual(fired, 5); XCTAssertTrue(d.ducked)
        XCTAssertFalse(d.micFrame(rms: 0.2, muted: false, playing: true), "only once")
        d.restore()
        XCTAssertFalse(d.ducked)
    }
    func testDuckDetectorIgnoresBleedAndMuted() {
        var d = DuckDetector()
        d.updateOutput(0.2)       // his own voice at the speaker: threshold becomes 0.24
        for _ in 0..<20 { XCTAssertFalse(d.micFrame(rms: 0.1, muted: false, playing: true)) }
        for _ in 0..<20 { XCTAssertFalse(d.micFrame(rms: 0.9, muted: true, playing: true)) }
        for _ in 0..<4 { XCTAssertFalse(d.micFrame(rms: 0.5, muted: false, playing: true)) }
        XCTAssertTrue(d.micFrame(rms: 0.5, muted: false, playing: true))
    }
    func testDuckLoudCounterResetsOnQuietFrame() {
        var d = DuckDetector()
        for _ in 0..<4 { _ = d.micFrame(rms: 0.2, muted: false, playing: true) }
        _ = d.micFrame(rms: 0.0, muted: false, playing: true)
        XCTAssertEqual(d.loud, 0)
    }
    func testLevelMeterAttackAndRelease() {
        var m = LevelMeter()
        m.push(0.4, muted: false); XCTAssertEqual(m.value, 0.4, accuracy: 1e-6)
        m.push(0.0, muted: false); XCTAssertEqual(m.value, 0.34, accuracy: 1e-6)
        m.push(0.9, muted: true); XCTAssertEqual(m.value, 0)
    }
}

final class TimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testStreamingTurnBuildsOneAssistantEntry() {
        var tl = TimelineReducer()
        tl.apply(.turnStarted(turnId: "t1", kind: "message", agent: nil, voice: false), now: t0)
        XCTAssertTrue(tl.busy)
        tl.apply(.textDelta(turnId: "t1", text: "Hel"), now: t0)
        tl.apply(.toolStarted(turnId: "t1", callId: "c", name: "fs.read", args: nil), now: t0)
        tl.apply(.textDelta(turnId: "t1", text: "lo"), now: t0)
        XCTAssertEqual(tl.entries.count, 1); XCTAssertEqual(tl.entries[0].text, "Hello"); XCTAssertTrue(tl.entries[0].streaming)
        tl.apply(.turnDone(.init(turnId: "t1", text: "Hello there", model: nil, costUsd: nil, toolsUsed: ["fs.read"])), now: t0)
        XCTAssertFalse(tl.busy); XCTAssertFalse(tl.entries[0].streaming); XCTAssertEqual(tl.entries[0].text, "Hello there")
        XCTAssertEqual(tl.entries[0].tools, ["fs.read"])
    }
    func testTurnDoneWithoutStartStillShows() {
        var tl = TimelineReducer()
        tl.apply(.turnDone(.init(turnId: "x", text: "late", model: nil, costUsd: nil, toolsUsed: [])), now: t0)
        XCTAssertEqual(tl.entries.map { $0.text }, ["late"])
    }
    func testFailedAndInterrupted() {
        var tl = TimelineReducer()
        tl.apply(.turnStarted(turnId: "a", kind: nil, agent: "friday", voice: true), now: t0)
        XCTAssertEqual(tl.entries[0].persona, "friday"); XCTAssertTrue(tl.entries[0].fromVoice)
        tl.apply(.turnInterrupted(turnId: "a"), now: t0)
        XCTAssertTrue(tl.entries[0].interrupted); XCTAssertFalse(tl.entries[0].streaming); XCTAssertFalse(tl.busy)
        tl.apply(.turnStarted(turnId: "b", kind: nil, agent: nil, voice: false), now: t0)
        tl.apply(.turnFailed(turnId: "b", message: "boom"), now: t0)
        XCTAssertTrue(tl.entries[1].failed); XCTAssertEqual(tl.entries[1].text, "boom")
    }
    func testVoiceCaptionAndDedupe() {
        var tl = TimelineReducer()
        tl.apply(.voicePartial("what is the"), now: t0)
        XCTAssertEqual(tl.caption, "what is the")
        tl.apply(.voiceFinal("what is the time"), now: t0)
        XCTAssertEqual(tl.caption, ""); XCTAssertEqual(tl.entries.count, 1); XCTAssertTrue(tl.entries[0].fromVoice)
        tl.apply(.userMessage(text: "what is the time", device: "x"), now: t0.addingTimeInterval(1))
        XCTAssertEqual(tl.entries.count, 1, "the echoed message does not duplicate the spoken words")
        tl.apply(.userMessage(text: "what is the time", device: "x"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(tl.entries.count, 2, "later repeat is a new message")
    }
    func testLocalUserMessageAlwaysAdds() {
        var tl = TimelineReducer()
        tl.addLocalUser("hi", now: t0); tl.addLocalUser("hi", now: t0)
        XCTAssertEqual(tl.entries.count, 2)
    }
    func testTasksFilesCommandsAndSessionReset() {
        var tl = TimelineReducer()
        let running = TaskInfo(id: "t", kind: nil, owner: "friday", name: "Friday", title: "Fix", status: "running")
        tl.apply(.taskUpdate(running), now: t0)
        XCTAssertEqual(tl.entries.count, 0, "progress updates do not clutter the chat")
        var done = running; done.status = "done"; done.summary = "ok"
        tl.apply(.taskUpdate(done), now: t0); tl.apply(.taskUpdate(done), now: t0)
        XCTAssertEqual(tl.entries.count, 1); XCTAssertEqual(tl.entries[0].detail, "ok")
        tl.apply(.commandResult(line: "/status", ok: true, text: "fine"), now: t0)
        XCTAssertEqual(tl.entries.last?.kind, .command)
        tl.apply(.commandResult(line: "/clear", ok: true, text: ""), now: t0)
        XCTAssertTrue(tl.entries.isEmpty)
        tl.apply(.sessionReset(number: 3, reason: "owner"), now: t0)
        XCTAssertEqual(tl.entries.count, 1); XCTAssertEqual(tl.entries[0].kind, .session)
    }
    func testPrependOlderDedupes() {
        var tl = TimelineReducer()
        func item(_ i: Int) -> HistoryItem {
            try! JSONDecoder().decode(HistoryItem.self, from: Data(#"{"id":"\#(i)","seq":\#(i),"kind":"message","role":"user","text":"m\#(i)"}"#.utf8))
        }
        tl.setHistory([item(3), item(4)], pageSize: 2)
        XCTAssertTrue(tl.hasOlder)
        tl.prepend([item(1), item(2), item(3)], pageSize: 60)
        XCTAssertEqual(tl.entries.map { $0.text }, ["m1", "m2", "m3", "m4"]); XCTAssertFalse(tl.hasOlder)
        XCTAssertEqual(tl.oldestSeq, 1)
    }
}

final class ResamplerTests: XCTestCase {
    func sine(_ f: Double, rate: Double, n: Int, amp: Double = 0.5) -> [Float] { (0..<n).map { Float(amp * sin(2 * .pi * f * Double($0) / rate)) } }
    func peak(_ x: [Float]) -> Float { x.map { abs($0) }.max() ?? 0 }

    func testRatioAndLength() {
        for rate in [48000.0, 44100.0, 32000.0, 16000.0] {
            var r = StreamResampler(inRate: rate, outRate: 16000)
            let out = r.process([Float](repeating: 0.1, count: Int(rate)))     // one second in
            XCTAssertCloseInt(out.count, 16000, 2)
        }
    }
    func testPreservesSpeechBandTone() {
        var r = StreamResampler(inRate: 48000, outRate: 16000)
        let out = r.process(sine(440, rate: 48000, n: 48000))
        XCTAssertEqual(peak(Array(out.dropFirst(100))), 0.5, accuracy: 0.06)
        var r2 = StreamResampler(inRate: 44100, outRate: 16000)
        XCTAssertEqual(peak(Array(r2.process(sine(1000, rate: 44100, n: 44100)).dropFirst(100))), 0.5, accuracy: 0.1)
    }
    func testAttenuatesAboveNyquist() {
        var r = StreamResampler(inRate: 48000, outRate: 16000)
        let out = r.process(sine(15000, rate: 48000, n: 48000))         // would alias to 1 kHz if not filtered
        XCTAssertLessThan(peak(Array(out.dropFirst(100))), 0.2)
    }
    func testChunkingDoesNotChangeTheResult() {
        let x = sine(300, rate: 44100, n: 20000)
        var whole = StreamResampler(inRate: 44100, outRate: 16000); let a = whole.process(x)
        var parts = StreamResampler(inRate: 44100, outRate: 16000); var b: [Float] = []
        var i = 0; let sizes = [1, 7, 100, 513, 1024, 3]
        var k = 0
        while i < x.count { let n = min(sizes[k % sizes.count], x.count - i); b += parts.process(Array(x[i..<(i + n)])); i += n; k += 1 }
        XCTAssertCloseInt(a.count, b.count, 1)
        for j in 0..<min(a.count, b.count) { XCTAssertEqual(a[j], b[j], accuracy: 1e-4) }
    }
    func testSameRateIsPassThrough() {
        var r = StreamResampler(inRate: 16000, outRate: 16000)
        XCTAssertEqual(r.process([0.1, 0.2, 0.3]), [0.1, 0.2, 0.3])
    }
}

func XCTAssertCloseInt(_ a: Int, _ b: Int, _ accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)", file: file, line: line)
}
