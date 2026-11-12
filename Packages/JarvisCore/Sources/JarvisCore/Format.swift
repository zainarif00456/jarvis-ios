import Foundation

public enum Format {
    /// Parses the server's timestamps: `2026-11-12T15:25:21.123Z`, `...+00:00`, or without fractions.
    public static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // naive UTC timestamp without a zone ("2026-11-12T15:25:21")
        let f3 = ISO8601DateFormatter(); f3.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f3.timeZone = TimeZone(identifier: "UTC")
        return f3.date(from: s)
    }

    public static func bytes(_ n: Int) -> String {
        let v = Double(max(0, n))
        if v < 1024 { return "\(Int(v)) B" }
        if v < 1024 * 1024 { return String(format: "%.0f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / 1024 / 1024) }
        return String(format: "%.2f GB", v / 1024 / 1024 / 1024)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// 0.0 ... 1.0 -> "42%"
    public static func percent(_ v: Double) -> String { "\(Int((max(0, min(1, v)) * 100).rounded()))%" }

    public static func usd(_ v: Double) -> String { String(format: "$%.4f", v) }

    /// A safe file name for a download or an upload (no path separators, never empty).
    public static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\0\n\r")
        var n = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : String(n.prefix(120))
    }
}
