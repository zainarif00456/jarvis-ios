import Foundation

/// Streaming mono downsampler (area averaging): each output sample is the average of the input over its window of
/// `inRate / outRate` input samples, with fractional edges weighted. A box filter is a good anti-alias filter for
/// speech, needs no tables, and handles any ratio (48000 -> 16000, 44100 -> 16000, 16000 -> 16000).
/// Chunk boundaries do not matter: feeding a signal in pieces gives the same samples as feeding it whole.
public struct StreamResampler: Sendable {
    public let inRate: Double
    public let outRate: Double
    private let step: Double                // input samples per output sample
    private var pending: [Float] = []       // input not yet consumed
    private var pos: Double = 0             // start of the next output window, in samples of `pending`

    public init(inRate: Double, outRate: Double) {
        self.inRate = max(1, inRate); self.outRate = max(1, outRate)
        step = self.inRate / self.outRate
    }

    public mutating func reset() { pending.removeAll(keepingCapacity: true); pos = 0 }

    /// Feed input samples (first channel, -1...1); returns whole output samples that are ready.
    public mutating func process(_ input: [Float]) -> [Float] {
        pending.append(contentsOf: input)
        var out: [Float] = []
        if step <= 1.0000001 {                      // same rate (or upsampling, not needed here): pass through
            if abs(step - 1) < 1e-6 { out = pending; pending.removeAll(keepingCapacity: true); pos = 0; return out }
        }
        while pos + step <= Double(pending.count) {
            let a = pos, b = pos + step
            var i = Int(a.rounded(.down))
            var sum: Double = 0
            while Double(i) < b {
                let lo = max(a, Double(i)), hi = min(b, Double(i + 1))
                if hi > lo { sum += Double(pending[i]) * (hi - lo) }
                i += 1
            }
            out.append(Float(sum / step))
            pos = b
        }
        let drop = Int(pos.rounded(.down))
        if drop > 0 { pending.removeFirst(drop); pos -= Double(drop) }
        return out
    }
}
