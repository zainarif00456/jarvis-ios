import Foundation

/// Reconnect delay schedule, mirroring the web client (js/net.js): the first retry is almost immediate
/// (a restart or a blip), then 1 s, 2 s, 4 s ... capped at 15 s, plus jitter so devices do not move in lockstep.
public struct Backoff: Sendable {
    public private(set) var attempt = 0
    public let jitterMs: Double
    public init(jitterMs: Double = 250) { self.jitterMs = jitterMs }

    /// Seconds to wait before the next attempt. `random` is a unit-interval sample (injectable for tests).
    public mutating func nextDelay(random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        attempt += 1
        let base: Double = attempt == 1 ? 250 : min(1000 * pow(2, Double(min(attempt - 2, 4))), 15000)
        return (base + random * jitterMs) / 1000
    }
    public mutating func reset() { attempt = 0 }
}
