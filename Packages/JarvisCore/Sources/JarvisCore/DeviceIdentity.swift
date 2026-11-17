import Foundation

/// Who is talking to Jarvis: which kind of client, which physical device, on which kind of network and route.
/// It rides along as plain `X-Jarvis-*` request headers on every request and WebSocket, so a server can tell this
/// phone apart from a browser on a laptop without a new endpoint. Servers that do not know the headers ignore them.
/// The install id is generated once on the device and kept in the Keychain; it is an identifier, not a secret.
public struct DeviceIdentity: Equatable, Sendable {
    public enum Network: String, Sendable { case wifi, cellular, wired, other, offline }

    public var client: String          // "ios-app"
    public var installID: String       // stable per install
    public var model: String           // hardware id, e.g. "iPhone14,3"
    public var name: String            // the name the owner gave this phone
    public var os: String              // "iOS 27.2"
    public var appVersion: String
    public var network: Network

    public init(client: String = "ios-app", installID: String, model: String, name: String, os: String,
                appVersion: String, network: Network) {
        self.client = client; self.installID = installID; self.model = model; self.name = name
        self.os = os; self.appVersion = appVersion; self.network = network
    }

    /// Header values must be plain ASCII on one line: anything else (an apostrophe or emoji in a phone name) is
    /// percent-encoded, and a server can decode it with any URL decoder.
    static func headerSafe(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " .-_,()/+:")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return String(encoded.prefix(120))
    }

    /// `route` says how the app reached the server (Tailscale, ngrok, LAN, direct); it comes from the saved address.
    public func headers(route: String?) -> [String: String] {
        var h = [
            "X-Jarvis-Client": DeviceIdentity.headerSafe(client),
            "X-Jarvis-Install": DeviceIdentity.headerSafe(installID),
            "X-Jarvis-Device-Model": DeviceIdentity.headerSafe(model),
            "X-Jarvis-Device-Name": DeviceIdentity.headerSafe(name),
            "X-Jarvis-OS": DeviceIdentity.headerSafe(os),
            "X-Jarvis-App": DeviceIdentity.headerSafe(appVersion),
            "X-Jarvis-Network": network.rawValue,
        ]
        if let r = route, !r.isEmpty { h["X-Jarvis-Route"] = DeviceIdentity.headerSafe(r) }
        return h.filter { !$0.value.isEmpty }
    }

    // MARK: the one place the running app publishes its identity

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DeviceIdentity?
        func get() -> DeviceIdentity? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: DeviceIdentity?) { lock.lock(); value = v; lock.unlock() }
    }
    private static let box = Box()

    /// The app sets this once at launch and again when the network kind changes. Requests read it; they never
    /// wait on the network or the Keychain, so building headers stays instant and cannot fail.
    public static func publish(_ identity: DeviceIdentity?) { box.set(identity) }
    public static var published: DeviceIdentity? { box.get() }
}
