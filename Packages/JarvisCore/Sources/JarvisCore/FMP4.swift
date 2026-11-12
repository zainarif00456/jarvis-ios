import Foundation

/// A tiny, bounds-checked reader. Malformed input throws instead of trapping.
struct ByteReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int
    init(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) { self.bytes = bytes; pos = from; end = min(to ?? bytes.count, bytes.count) }
    var remaining: Int { end - pos }
    mutating func u8() throws -> Int { guard pos < end else { throw FMP4Error.truncated }; defer { pos += 1 }; return Int(bytes[pos]) }
    mutating func u16() throws -> Int { try (u8() << 8) | u8() }
    mutating func u32() throws -> Int { try (u16() << 16) | u16() }
    mutating func i32() throws -> Int { let v = try u32(); return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
    mutating func u64() throws -> UInt64 { let hi = UInt64(try u32()); let lo = UInt64(try u32()); return (hi << 32) | lo }
    mutating func skip(_ n: Int) throws { guard n >= 0, pos + n <= end else { throw FMP4Error.truncated }; pos += n }
    mutating func take(_ n: Int) throws -> [UInt8] { guard n >= 0, pos + n <= end else { throw FMP4Error.truncated }; defer { pos += n }; return Array(bytes[pos..<(pos + n)]) }
    mutating func fourCC() throws -> String { String(decoding: try take(4), as: UTF8.self) }
}

public enum FMP4Error: Error, Equatable { case truncated, corrupt(String), unsupported(String) }

/// The video track described by an fMP4 init segment (`ftyp` + `moov`).
public struct VideoTrack: Equatable, Sendable {
    public var trackId: Int
    public var timescale: Int
    public var width: Int
    public var height: Int
    public var codec: String            // "avc1" (H.264) or "hvc1"/"hev1" (unsupported by this demuxer)
    public var sps: [[UInt8]]
    public var pps: [[UInt8]]
    public var nalLengthSize: Int
    public var defaultDuration: Int
    public var defaultSize: Int
    public var defaultFlags: Int
    public var hasAudio: Bool
}

/// One compressed video frame: length-prefixed NAL units (AVCC), times in `timescale` units.
public struct VideoSample: Equatable, Sendable {
    public var data: [UInt8]
    public var dts: Int64
    public var pts: Int64
    public var duration: Int
    public var isSync: Bool
}

public enum FMP4Event: Equatable, Sendable {
    case initSegment(VideoTrack)
    case samples([VideoSample])
}

/// Turns the camera WebSocket's binary frames (an init segment, then `moof`+`mdat` fragments) into H.264
/// frames ready for a hardware decoder. Pure data: tested on Linux, then fed to
/// `AVSampleBufferDisplayLayer` on iOS. Accepts any chunking: it only acts on whole top-level boxes.
public final class FMP4Demuxer {
    private var buffer: [UInt8] = []
    public private(set) var track: VideoTrack?
    private var pendingMoof: (bytes: [UInt8], offsetInStream: Int)?
    private var streamOffset = 0
    private var nextDts: Int64 = 0
    public static let maxBuffer = 16 * 1024 * 1024

    public init() {}

    public func reset() { buffer.removeAll(); track = nil; pendingMoof = nil; streamOffset = 0; nextDts = 0 }

    public func push(_ data: Data) throws -> [FMP4Event] {
        buffer.append(contentsOf: data)
        if buffer.count > Self.maxBuffer { reset(); throw FMP4Error.corrupt("buffer overflow") }
        var events: [FMP4Event] = []
        var moovBytes: [UInt8]? = nil
        while buffer.count >= 8 {
            var r = ByteReader(buffer)
            var size = try r.u32()
            let kind = try r.fourCC()
            var header = 8
            if size == 1 {
                guard buffer.count >= 16 else { break }
                size = Int(clamping: try r.u64()); header = 16
            } else if size == 0 { size = buffer.count }
            guard size >= header else { reset(); throw FMP4Error.corrupt("box size \(size)") }
            guard buffer.count >= size else { break }
            let box = Array(buffer[0..<size])
            buffer.removeFirst(size)
            switch kind {
            case "moov":
                moovBytes = box
                let t = try Self.parseMoov(box)
                track = t
                nextDts = 0
                events.append(.initSegment(t))
            case "moof":
                pendingMoof = (box, 0)
            case "mdat":
                if let t = track, let moof = pendingMoof {
                    let samples = try Self.parseFragment(moof: moof.bytes, mdat: box, mdatHeader: header, track: t, nextDts: &nextDts)
                    if !samples.isEmpty { events.append(.samples(samples)) }
                }
                pendingMoof = nil
            default: break   // ftyp, styp, sidx, free ...
            }
        }
        _ = moovBytes
        return events
    }

    // MARK: box tree

    /// Child boxes of a container: (type, payload range in `bytes`).
    static func children(_ bytes: [UInt8], from: Int, to: Int) -> [(type: String, start: Int, end: Int)] {
        var out: [(String, Int, Int)] = []
        var pos = from
        while pos + 8 <= to {
            var r = ByteReader(bytes, from: pos, to: to)
            guard var size = try? r.u32(), let kind = try? r.fourCC() else { break }
            var header = 8
            if size == 1 { guard let big = try? r.u64() else { break }; size = Int(clamping: big); header = 16 }
            else if size == 0 { size = to - pos }
            guard size >= header, pos + size <= to else { break }
            out.append((kind, pos + header, pos + size))
            pos += size
        }
        return out
    }

    static func find(_ bytes: [UInt8], _ path: [String], from: Int, to: Int) -> (start: Int, end: Int)? {
        var range = (from, to)
        for name in path {
            guard let c = children(bytes, from: range.0, to: range.1).first(where: { $0.type == name }) else { return nil }
            range = (c.start, c.end)
        }
        return range
    }

    static func parseMoov(_ box: [UInt8]) throws -> VideoTrack {
        // `box` includes its own 8 byte header; children start after it
        let moov = (start: 8, end: box.count)
        var video: VideoTrack?
        var hasAudio = false
        var trexDefaults: [Int: (dur: Int, size: Int, flags: Int)] = [:]
        if let mvex = find(box, ["mvex"], from: moov.start, to: moov.end) {
            for c in children(box, from: mvex.start, to: mvex.end) where c.type == "trex" {
                var r = ByteReader(box, from: c.start, to: c.end)
                try r.skip(4)
                let id = try r.u32(); try r.skip(4)
                let dur = try r.u32(), size = try r.u32(), flags = try r.u32()
                trexDefaults[id] = (dur, size, flags)
            }
        }
        for trak in children(box, from: moov.start, to: moov.end) where trak.type == "trak" {
            guard let mdia = find(box, ["mdia"], from: trak.start, to: trak.end) else { continue }
            var handler = ""
            if let hdlr = find(box, ["hdlr"], from: mdia.start, to: mdia.end) {
                var r = ByteReader(box, from: hdlr.start, to: hdlr.end)
                try r.skip(8); handler = try r.fourCC()
            }
            if handler == "soun" { hasAudio = true; continue }
            guard handler == "vide" else { continue }
            var trackId = 1, width = 0, height = 0
            if let tkhd = find(box, ["tkhd"], from: trak.start, to: trak.end) {
                var r = ByteReader(box, from: tkhd.start, to: tkhd.end)
                let version = try r.u8(); try r.skip(3)
                if version == 1 { try r.skip(16) } else { try r.skip(8) }
                trackId = try r.u32()
                try r.skip(4 + (version == 1 ? 8 : 4) + 8 + 2 + 2 + 2 + 2 + 36)
                width = try r.u32() >> 16; height = try r.u32() >> 16
            }
            var timescale = 90_000
            if let mdhd = find(box, ["mdhd"], from: mdia.start, to: mdia.end) {
                var r = ByteReader(box, from: mdhd.start, to: mdhd.end)
                let version = try r.u8(); try r.skip(3)
                try r.skip(version == 1 ? 16 : 8)
                timescale = try r.u32()
            }
            guard let stsd = find(box, ["minf", "stbl", "stsd"], from: mdia.start, to: mdia.end) else { throw FMP4Error.corrupt("no stsd") }
            var r = ByteReader(box, from: stsd.start, to: stsd.end)
            try r.skip(8)                                   // version/flags + entry count
            let entryStart = r.pos
            let entrySize = try r.u32()
            let codec = try r.fourCC()
            guard entrySize >= 86, entryStart + entrySize <= stsd.end else { throw FMP4Error.corrupt("short sample entry") }
            // visual sample entry: 6 reserved + 2 index + 16 + width + height + ... 78 bytes before child boxes
            let childrenStart = entryStart + 8 + 78
            var sps: [[UInt8]] = [], pps: [[UInt8]] = [], nalSize = 4
            if codec == "avc1" || codec == "avc3" {
                guard let avcc = children(box, from: childrenStart, to: entryStart + entrySize).first(where: { $0.type == "avcC" }) else { throw FMP4Error.corrupt("no avcC") }
                var a = ByteReader(box, from: avcc.start, to: avcc.end)
                try a.skip(4)
                nalSize = (try a.u8() & 3) + 1
                let nsps = try a.u8() & 0x1F
                for _ in 0..<nsps { let len = try a.u16(); sps.append(try a.take(len)) }
                let npps = try a.u8()
                for _ in 0..<npps { let len = try a.u16(); pps.append(try a.take(len)) }
            }
            let d = trexDefaults[trackId] ?? (0, 0, 0)
            video = VideoTrack(trackId: trackId, timescale: max(1, timescale), width: width, height: height, codec: codec, sps: sps, pps: pps,
                               nalLengthSize: nalSize, defaultDuration: d.dur, defaultSize: d.size, defaultFlags: d.flags, hasAudio: false)
        }
        guard var v = video else { throw FMP4Error.unsupported("no video track in this stream") }
        v.hasAudio = hasAudio
        if v.codec != "avc1" && v.codec != "avc3" { throw FMP4Error.unsupported("video codec \(v.codec) (only H.264 is supported)") }
        return v
    }

    static func parseFragment(moof: [UInt8], mdat: [UInt8], mdatHeader: Int, track: VideoTrack, nextDts: inout Int64) throws -> [VideoSample] {
        var out: [VideoSample] = []
        for traf in children(moof, from: 8, to: moof.count) where traf.type == "traf" {
            var trackId = 0
            var baseDataOffset: Int? = nil
            var defDur = track.defaultDuration, defSize = track.defaultSize, defFlags = track.defaultFlags
            var decodeTime: Int64? = nil
            for c in children(moof, from: traf.start, to: traf.end) {
                if c.type == "tfhd" {
                    var r = ByteReader(moof, from: c.start, to: c.end)
                    let flags = try r.u32() & 0xFFFFFF
                    trackId = try r.u32()
                    if flags & 0x1 != 0 { baseDataOffset = Int(clamping: try r.u64()) }
                    if flags & 0x2 != 0 { try r.skip(4) }
                    if flags & 0x8 != 0 { defDur = try r.u32() }
                    if flags & 0x10 != 0 { defSize = try r.u32() }
                    if flags & 0x20 != 0 { defFlags = try r.u32() }
                } else if c.type == "tfdt" {
                    var r = ByteReader(moof, from: c.start, to: c.end)
                    let version = try r.u8(); try r.skip(3)
                    decodeTime = version == 1 ? Int64(clamping: try r.u64()) : Int64(try r.u32())
                }
            }
            guard trackId == track.trackId else { continue }   // audio and other tracks are skipped
            var dts = decodeTime ?? nextDts
            for c in children(moof, from: traf.start, to: traf.end) where c.type == "trun" {
                var r = ByteReader(moof, from: c.start, to: c.end)
                let flagsWord = try r.u32()
                let flags = flagsWord & 0xFFFFFF
                let count = try r.u32()
                guard count <= 100_000 else { throw FMP4Error.corrupt("sample count \(count)") }
                var dataOffset = 0
                if flags & 0x1 != 0 { dataOffset = try r.i32() }
                var firstFlags: Int? = nil
                if flags & 0x4 != 0 { firstFlags = try r.u32() }
                // data_offset is relative to the start of the moof (default-base-is-moof) unless a base offset was given;
                // `mdat` starts right after `moof` in these streams, so offset into the mdat payload:
                let base = baseDataOffset ?? 0
                var pos = (dataOffset - (moof.count + mdatHeader)) + (baseDataOffset != nil ? 0 : 0)
                _ = base
                if pos < 0 { pos = 0 }
                for i in 0..<count {
                    let dur = flags & 0x100 != 0 ? try r.u32() : defDur
                    let size = flags & 0x200 != 0 ? try r.u32() : defSize
                    var sflags = defFlags
                    if flags & 0x400 != 0 { sflags = try r.u32() } else if i == 0, let ff = firstFlags { sflags = ff }
                    let cts = flags & 0x800 != 0 ? try r.i32() : 0
                    let start = mdatHeader + pos, stop = start + size
                    guard size >= 0, stop <= mdat.count else { throw FMP4Error.truncated }
                    let isSync = (sflags & 0x10000) == 0     // sample_is_non_sync_sample bit clear
                    out.append(VideoSample(data: Array(mdat[start..<stop]), dts: dts, pts: dts + Int64(cts), duration: dur, isSync: isSync))
                    pos += size
                    dts += Int64(dur)
                }
            }
            nextDts = dts
        }
        return out
    }
}

/// Helpers for turning AVCC data into what decoders want.
public enum H264 {
    /// NAL unit types present in an AVCC sample (for tests and for spotting IDR frames).
    public static func nalTypes(of sample: [UInt8], lengthSize: Int = 4) -> [Int] {
        var types: [Int] = []
        var i = 0
        while i + lengthSize < sample.count {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(sample[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= sample.count else { break }
            types.append(Int(sample[i] & 0x1F))
            i += len
        }
        return types
    }
}
