import Foundation

/// Wire-format audio maths. Up: 16 kHz, 16-bit little-endian mono, 40 ms frames (640 samples, 1280 bytes).
/// Down: 24 kHz, 16-bit little-endian mono, arriving faster than real time.
public enum PCM {
    public static let micRate = 16_000
    public static let ttsRate = 24_000
    public static let frameSamples = 640
    public static let frameBytes = 1280

    /// Decodes little-endian Int16 samples; an odd trailing byte is ignored.
    public static func int16(from data: Data) -> [Int16] {
        let n = data.count / 2
        var out = [Int16](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            for i in 0..<n {
                let lo = UInt16(raw[2 * i]); let hi = UInt16(raw[2 * i + 1])
                out[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        return out
    }

    public static func data(from samples: [Int16]) -> Data {
        var d = Data(count: samples.count * 2)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
            for (i, s) in samples.enumerated() {
                let u = UInt16(bitPattern: s)
                raw[2 * i] = UInt8(u & 0xff); raw[2 * i + 1] = UInt8(u >> 8)
            }
        }
        return d
    }

    public static func floats(from samples: [Int16]) -> [Float] { samples.map { Float($0) / 32768 } }

    public static func int16(fromFloats f: [Float]) -> [Int16] {
        f.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
    }

    /// Root-mean-square loudness of 16-bit samples, 0...1.
    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { let f = Float(s) / 32768; sum += f * f }
        return (sum / Float(samples.count)).squareRoot()
    }
    public static func rms(_ data: Data) -> Float { rms(int16(from: data)) }

    /// Seconds of audio in a 24 kHz Int16 chunk.
    public static func ttsSeconds(bytes: Int) -> Double { Double(bytes) / Double(ttsRate * 2) }
}

/// Collects mic bytes and releases exact 40 ms frames.
public struct FrameChunker: Sendable {
    public let frameBytes: Int
    private var pending = Data()
    public init(frameBytes: Int = PCM.frameBytes) { self.frameBytes = frameBytes }
    public var buffered: Int { pending.count }

    public mutating func push(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var out: [Data] = []
        while pending.count >= frameBytes {
            out.append(Data(pending.prefix(frameBytes)))
            pending.removeFirst(frameBytes)
        }
        return out
    }
    public mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Server speech arrives as arbitrary chunks; a chunk can end in the middle of a sample. This keeps the stray
/// byte for the next chunk so samples stay aligned (otherwise the audio turns into static).
public struct SampleAligner: Sendable {
    private var carry: UInt8?
    public init() {}
    public mutating func push(_ chunk: Data) -> [Int16] {
        var data = Data()
        if let c = carry { data.append(c); carry = nil }
        data.append(chunk)
        if data.count % 2 == 1 { carry = data.last; data.removeLast() }
        return PCM.int16(from: data)
    }
    public mutating func reset() { carry = nil }
}

/// Decides when the owner is talking over Jarvis so playback can be softened at once (before the server
/// confirms real speech with `voice_stop`). Port of js/voice.js: the mic must beat both a fixed floor and
/// the speaker's own output (bleed), for several frames in a row.
public struct DuckDetector: Sendable {
    public static let floor: Float = 0.03
    public static let bleed: Float = 1.2
    public static let framesNeeded = 5
    public static let gain: Float = 0.2
    public static let restoreSeconds = 1.1

    public private(set) var loud = 0
    public private(set) var outLevel: Float = 0
    public private(set) var ducked = false

    public init() {}

    /// Feed the output loudness the player reports (decays like the web client's `outRms`).
    public mutating func updateOutput(_ level: Float) { outLevel = max(level, outLevel * 0.8) }
    public mutating func outputIdle() { outLevel = 0 }

    /// Returns true on the frame the duck should start.
    public mutating func micFrame(rms: Float, muted: Bool, playing: Bool) -> Bool {
        let threshold = max(Self.floor, outLevel * Self.bleed)
        loud = (!muted && rms > threshold) ? loud + 1 : 0
        if playing, !ducked, loud >= Self.framesNeeded { ducked = true; return true }
        return false
    }
    public mutating func restore() { ducked = false; loud = 0 }
}

/// Mic level smoothing for the orb (fast attack, slow release), as in the web client.
public struct LevelMeter: Sendable {
    public private(set) var value: Float = 0
    public init() {}
    public mutating func push(_ rms: Float, muted: Bool) { value = muted ? 0 : max(rms, value * 0.85) }
    public mutating func reset() { value = 0 }
}
