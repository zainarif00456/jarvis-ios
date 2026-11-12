import Foundation

/// Recognises an HTML page where JSON was expected: ngrok's free-plan warning / error page, a captive portal,
/// a wrong URL that hits some other web server.
public enum ResponseSniffer {
    public static func looksLikeHTML(contentType: String?, body: Data) -> Bool {
        if let ct = contentType?.lowercased(), ct.contains("text/html") { return true }
        let head = String(decoding: body.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<head") || head.hasPrefix("<body")
    }
    public static let htmlMessage = "The address answered with a web page, not Jarvis (an ngrok warning page or the wrong URL). Check the address."
}
