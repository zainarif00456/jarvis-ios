import Foundation

/// The AI team: names, colours and the shape each gives the core (js/core/personas.js, same values).
public struct Persona: Equatable, Sendable {
    public let key: String
    public let name: String
    public let role: String
    public let color: [Double]     // RGB 0...1
    public let color2: [Double]
    public let signature: Int      // 0 layered sphere, 1 knotted heart, 2 faceted lattice, 3 spiral arms
    public let isAI: Bool

    static func rgb(_ hex: String) -> [Double] {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return [0.3, 0.8, 0.94] }
        return [Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255]
    }

    public static let jarvis = Persona(key: "jarvis", name: "Jarvis", role: "Your assistant", color: rgb("#4cc9f0"), color2: rgb("#9be8ff"), signature: 0, isAI: true)
    public static let friday = Persona(key: "friday", name: "Friday", role: "Claude Code", color: rgb("#f59e0b"), color2: rgb("#ffd27a"), signature: 1, isAI: true)
    public static let edith = Persona(key: "edith", name: "EDITH", role: "Copilot", color: rgb("#3ee0a1"), color2: rgb("#a6f7d6"), signature: 2, isAI: true)
    public static let veronica = Persona(key: "veronica", name: "Veronica", role: "Codex", color: rgb("#c084fc"), color2: rgb("#e6c8ff"), signature: 3, isAI: true)
    public static let you = Persona(key: "you", name: "You", role: "Owner", color: rgb("#94a3b8"), color2: rgb("#cbd5e1"), signature: 0, isAI: false)
    public static let team: [Persona] = [.jarvis, .friday, .edith, .veronica]

    public static func of(_ key: String?) -> Persona {
        switch (key ?? "jarvis").lowercased() {
        case "jarvis": return .jarvis
        case "friday": return .friday
        case "edith": return .edith
        case "veronica": return .veronica
        case "you", "user": return .you
        default: return .jarvis
        }
    }
}
