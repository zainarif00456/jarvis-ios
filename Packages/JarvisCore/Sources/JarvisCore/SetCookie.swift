import Foundation

/// Reads the device cookie out of `Set-Cookie` header text. Done by hand (not HTTPCookie) so it behaves the
/// same on Linux and iOS, and never needs a cookie jar: the token goes to the Keychain, not to URLSession.
public enum SetCookie {
    /// `headerValue` may hold several cookies joined with ", " (some HTTP stacks fold them).
    public static func value(named name: String, in headerValue: String) -> String? {
        for piece in splitCookies(headerValue) {
            let first = piece.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            guard let eq = first.firstIndex(of: "=") else { continue }
            let key = first[first.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            if key == name {
                let v = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    /// Splits "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2" without cutting the Expires date.
    static func splitCookies(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let parts = text.components(separatedBy: ", ")
        for part in parts {
            let lower = current.lowercased()
            if !current.isEmpty, lower.contains("expires="), !current.contains("GMT"), !lower.hasSuffix("gmt") {
                current += ", " + part  // the comma was inside an Expires date
            } else {
                if !current.isEmpty { out.append(current) }
                current = part
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
