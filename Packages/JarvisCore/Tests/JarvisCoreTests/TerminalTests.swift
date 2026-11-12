import XCTest
@testable import JarvisCore

final class TerminalTests: XCTestCase {
    func term(_ cols: Int = 20, _ rows: Int = 5) -> TerminalEmulator { TerminalEmulator(cols: cols, rows: rows) }

    func testPlainTextAndNewlines() {
        let t = term(); t.feed("hello\r\nworld")
        XCTAssertEqual(t.buffer.lines()[0], "hello"); XCTAssertEqual(t.buffer.lines()[1], "world")
        XCTAssertEqual(t.buffer.cursorY, 1); XCTAssertEqual(t.buffer.cursorX, 5)
    }
    func testLineFeedAloneKeepsColumn() {
        let t = term(); t.feed("ab\ncd")
        XCTAssertEqual(t.buffer.lines()[0], "ab"); XCTAssertEqual(t.buffer.lines()[1], "  cd")
    }
    func testWrapAtEndOfLine() {
        let t = term(5, 3); t.feed("abcdefgh")
        XCTAssertEqual(t.buffer.lines()[0], "abcde"); XCTAssertEqual(t.buffer.lines()[1], "fgh")
    }
    func testScrollIntoScrollback() {
        let t = term(10, 3); t.feed("1\r\n2\r\n3\r\n4\r\n5")
        XCTAssertEqual(t.buffer.lines(), ["3", "4", "5"])
        XCTAssertEqual(t.buffer.scrollback.count, 2)
        XCTAssertEqual(String(t.buffer.scrollback[0][0].character), "1")
    }
    func testCursorMovementAndErase() {
        let t = term()
        t.feed("abcdef\u{1B}[3D\u{1B}[K")          // back 3, erase to end of line
        XCTAssertEqual(t.buffer.lines()[0], "abc")
        t.feed("\u{1B}[2;5HX")                     // row 2 col 5
        XCTAssertEqual(t.buffer.lines()[1], "    X")
        t.feed("\u{1B}[2J\u{1B}[H")
        XCTAssertEqual(t.buffer.text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(t.buffer.cursorX, 0); XCTAssertEqual(t.buffer.cursorY, 0)
    }
    func testSGRColoursAndReset() {
        let t = term()
        t.feed("\u{1B}[1;31mR\u{1B}[0mN\u{1B}[38;5;200mP\u{1B}[48;2;1;2;3mT\u{1B}[39;49mD")
        let row = t.buffer.grid[0]
        XCTAssertEqual(row[0].style.fg, .indexed(1)); XCTAssertTrue(row[0].style.attrs.contains(.bold))
        XCTAssertEqual(row[1].style, TermStyle())
        XCTAssertEqual(row[2].style.fg, .indexed(200))
        XCTAssertEqual(row[3].style.bg, .rgb(1, 2, 3)); XCTAssertEqual(row[3].style.fg, .indexed(200))
        XCTAssertEqual(row[4].style.fg, .default); XCTAssertEqual(row[4].style.bg, .default)
        t.feed("\u{1B}[92mB"); XCTAssertEqual(t.buffer.grid[0][5].style.fg, .indexed(10))
    }
    func testUTF8SplitAcrossChunks() {
        let t = term()
        let bytes = Array("é€😀".utf8)
        t.feed(Data(bytes[0..<1])); t.feed(Data(bytes[1..<3])); t.feed(Data(bytes[3...]))
        XCTAssertEqual(t.buffer.lines()[0], "é€😀")
        XCTAssertEqual(t.buffer.grid[0][2].scalar, 0x1F600); XCTAssertEqual(t.buffer.grid[0][3].scalar, 0, "wide char uses two cells")
    }
    func testAlternateScreenRestoresMain() {
        let t = term()
        t.feed("main text")
        t.feed("\u{1B}[?1049h\u{1B}[HVIM")
        XCTAssertEqual(t.buffer.lines()[0], "VIM"); XCTAssertTrue(t.buffer.usingAlternate)
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(t.buffer.lines()[0], "main text"); XCTAssertFalse(t.buffer.usingAlternate)
        XCTAssertEqual(t.buffer.cursorX, 9)
    }
    func testScrollRegionAndInsertDeleteLines() {
        let t = term(5, 5)
        t.feed("1\r\n2\r\n3\r\n4\r\n5")
        t.feed("\u{1B}[2;4r")      // region rows 2-4; cursor goes home
        t.feed("\u{1B}[4;1H\n")    // line feed at bottom of region scrolls only the region
        XCTAssertEqual(t.buffer.lines(), ["1", "3", "4", "", "5"])
        t.feed("\u{1B}[2;1H\u{1B}[M")  // delete a line inside the region
        XCTAssertEqual(t.buffer.lines()[1], "4")
    }
    func testResponsesToQueries() {
        let t = term(); var out = Data()
        t.onResponse = { out.append($0) }
        t.feed("ab\u{1B}[6n")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\u{1B}[1;3R")
        out.removeAll(); t.feed("\u{1B}[c"); XCTAssertEqual(String(decoding: out, as: UTF8.self), "\u{1B}[?1;2c")
    }
    func testModesAndTitle() {
        let t = term()
        t.feed("\u{1B}[?25l"); XCTAssertFalse(t.buffer.cursorVisible)
        t.feed("\u{1B}[?25h"); XCTAssertTrue(t.buffer.cursorVisible)
        t.feed("\u{1B}[?1h"); XCTAssertTrue(t.buffer.applicationCursorKeys)
        t.feed("\u{1B}[?2004h"); XCTAssertTrue(t.buffer.bracketedPaste)
        t.feed("\u{1B}]0;my title\u{07}"); XCTAssertEqual(t.buffer.title, "my title")
        t.feed("\u{1B}]2;other\u{1B}\\"); XCTAssertEqual(t.buffer.title, "other")
    }
    func testBrokenSequencesDoNotCrashOrStick() {
        let t = term()
        t.feed(Data([0x1B, 0x5B, 0x31, 0x3B, 0xFF, 0xC3, 0x28, 0x1B, 0x1B, 0x1B, 0x5D, 0x07]))
        t.feed("ok")
        XCTAssertTrue(t.buffer.text.contains("ok"))
        // fuzz: random bytes never trap
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let d = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &rng) })
            t.feed(d)
            t.resize(cols: Int.random(in: 2...40, using: &rng), rows: Int.random(in: 1...20, using: &rng))
        }
        XCTAssertEqual(t.buffer.grid.count, t.buffer.rows); XCTAssertTrue(t.buffer.grid.allSatisfy { $0.count == t.buffer.cols })
    }
    func testResizeKeepsGridConsistent() {
        let t = term(10, 4); t.feed("a\r\nb\r\nc\r\nd")
        t.resize(cols: 6, rows: 2)
        XCTAssertEqual(t.buffer.grid.count, 2); XCTAssertEqual(t.buffer.lines(), ["c", "d"])
        t.resize(cols: 12, rows: 6)
        XCTAssertEqual(t.buffer.grid.count, 6); XCTAssertTrue(t.buffer.grid.allSatisfy { $0.count == 12 })
    }
    func testDECLineDrawing() {
        let t = term(); t.feed("\u{1B}(0lqk\u{1B}(Bq")
        XCTAssertEqual(t.buffer.lines()[0], "┌─┐q")
    }
    func testKeys() {
        XCTAssertEqual(TerminalKeys.bytes(for: .up), Data("\u{1B}[A".utf8))
        XCTAssertEqual(TerminalKeys.bytes(for: .up, applicationCursor: true), Data("\u{1B}OA".utf8))
        XCTAssertEqual(TerminalKeys.control("c"), Data([3])); XCTAssertEqual(TerminalKeys.control("D"), Data([4]))
        XCTAssertEqual(TerminalKeys.control("["), Data([27])); XCTAssertNil(TerminalKeys.control("é"))
        XCTAssertEqual(TerminalKeys.paste("a\nb", bracketed: true), Data("\u{1B}[200~a\rb\u{1B}[201~".utf8))
        XCTAssertEqual(TerminalKeys.bytes(for: .tab), Data([9]))
    }
}

final class FMP4Tests: XCTestCase {
    func testDemuxesRealFfmpegClip() throws {
        let d = FMP4Demuxer()
        let events = try d.push(Fixtures.smallFMP4)
        guard case .initSegment(let track)? = events.first else { return XCTFail("no init segment: \(events.count)") }
        XCTAssertEqual(track.width, 160); XCTAssertEqual(track.height, 120)
        XCTAssertEqual(track.codec, "avc1"); XCTAssertEqual(track.nalLengthSize, 4)
        XCTAssertEqual(track.sps.count, 1); XCTAssertEqual(track.pps.count, 1)
        XCTAssertEqual(track.sps[0][0] & 0x1F, 7, "SPS NAL type"); XCTAssertEqual(track.pps[0][0] & 0x1F, 8, "PPS NAL type")
        XCTAssertFalse(track.hasAudio)
        var samples: [VideoSample] = []
        for e in events { if case .samples(let s) = e { samples += s } }
        XCTAssertEqual(samples.count, 15)
        XCTAssertTrue(samples[0].isSync)
        XCTAssertEqual(samples.filter { $0.isSync }.count, 3, "GOP of 5 frames: 3 key frames")
        XCTAssertTrue(H264.nalTypes(of: samples[0].data).contains(5), "first frame holds an IDR slice")
        XCTAssertFalse(H264.nalTypes(of: samples[1].data).contains(5))
        // timing: 15 fps, monotonically increasing
        for i in 1..<samples.count { XCTAssertGreaterThan(samples[i].dts, samples[i - 1].dts) }
        let seconds = Double(samples.last!.dts - samples[0].dts) / Double(track.timescale) * 15 / 14
        XCTAssertEqual(seconds, 1.0, accuracy: 0.15)
        // every sample is whole NAL units
        for s in samples { XCTAssertFalse(H264.nalTypes(of: s.data).isEmpty) }
    }

    func testAnyChunkingGivesTheSameResult() throws {
        func run(_ size: Int) throws -> (VideoTrack?, [VideoSample]) {
            let d = FMP4Demuxer(); var all: [VideoSample] = []
            var i = 0; let bytes = Fixtures.smallFMP4
            while i < bytes.count {
                for e in try d.push(bytes.subdata(in: i..<min(bytes.count, i + size))) { if case .samples(let s) = e { all += s } }
                i += size
            }
            return (d.track, all)
        }
        let whole = try run(Int.max / 2)
        for size in [1, 7, 100, 4096] {
            let r = try run(size)
            XCTAssertEqual(r.1, whole.1, "chunk size \(size)"); XCTAssertEqual(r.0, whole.0)
        }
    }

    func testMalformedInputThrowsOrIgnoresNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let d = FMP4Demuxer()
            var bytes = Array(Fixtures.smallFMP4.prefix(3000))
            for _ in 0..<12 { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? d.push(Data(bytes))
        }
        let d = FMP4Demuxer()
        XCTAssertThrowsError(try d.push(Data([0, 0, 0, 4, 0x6d, 0x6f, 0x6f, 0x76])))   // size smaller than its header
        let e = FMP4Demuxer()
        XCTAssertEqual(try e.push(Data([0, 0, 1])), [], "incomplete header waits for more")
    }

    func testFragmentWithoutInitIsIgnored() throws {
        let whole = Fixtures.smallFMP4
        let d = FMP4Demuxer()
        // skip ftyp+moov: find first moof
        let idx = whole.range(of: Data("moof".utf8))!.lowerBound - 4
        let events = try d.push(whole.subdata(in: idx..<whole.count))
        XCTAssertTrue(events.isEmpty)
    }
}

final class TermPaletteTests: XCTestCase {
    func testPalette() {
        XCTAssertEqual(TermPalette.rgb(0).0, 0x1e); XCTAssertEqual(TermPalette.rgb(15).0, 0xf8)
        XCTAssertTrue(TermPalette.rgb(16) == (0, 0, 0)); XCTAssertTrue(TermPalette.rgb(231) == (255, 255, 255))
        XCTAssertTrue(TermPalette.rgb(196) == (255, 0, 0)); XCTAssertTrue(TermPalette.rgb(232) == (8, 8, 8)); XCTAssertTrue(TermPalette.rgb(255) == (238, 238, 238))
    }
    func testResolve() {
        var s = TermStyle(); s.fg = .indexed(1); s.attrs = [.bold]
        XCTAssertTrue(TermPalette.resolve(s).fg == TermPalette.rgb(9), "bold red is bright red")
        s = TermStyle(); s.attrs = [.inverse]
        let r = TermPalette.resolve(s)
        XCTAssertTrue(r.fg == TermPalette.defaultBackground && r.bg == TermPalette.defaultForeground)
    }
}
