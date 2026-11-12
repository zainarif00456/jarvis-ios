import Foundation
import JarvisCore

/// One saved server address ("Tailscale", "ngrok", "LAN"...). `address` is the canonical text (`Endpoint.canonicalText`).
public struct SavedServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var endpoint: Endpoint? { try? Endpoint.parse(address) }
    public init(id: String = UUID().uuidString, name: String, address: String) { self.id = id; self.name = name; self.address = address }
}

public enum ServerListError: Error, Equatable, LocalizedError {
    case duplicate(String), cannotDeleteActive, notFound, saveFailed
    public var errorDescription: String? {
        switch self {
        case .duplicate(let n): return "\"\(n)\" already uses that address."
        case .cannotDeleteActive: return "Switch to another address before deleting the one in use."
        case .notFound: return "That address no longer exists."
        case .saveFailed: return "Could not save to the Keychain."
        }
    }
}

/// Persistent user settings (UserDefaults) and device tokens (Keychain). No secret ever goes to UserDefaults or logs.
///
/// Keychain layout: ONE token per saved address, key `device-token.<server id>`. The token belongs to the Jarvis
/// server, not to the URL, so when the owner switches to an address that has no token yet the model first tries the
/// token of the current address (`GET /api/session` says whether the server knows it) and, if the server accepts it,
/// stores a copy under the new address; otherwise that address needs its own pairing. Two addresses of one server may
/// therefore hold the same token string; deleting an address deletes only its own copy. The old single-address
/// layout (`endpoint` + `device-token`) is migrated on first launch.
@MainActor
public final class SettingsStore: ObservableObject {
    enum Key {
        static let execLevel = "execLevel", screenState = "sendScreenState", effects = "effects", live = "liveExecution"
        static let endpoint = "endpoint", deviceName = "deviceName", autoStart = "autoStartCall", keepAwake = "keepAwake", haptics = "haptics"
        static let legacyToken = "device-token", servers = "servers", activeServer = "activeServer"
        static func token(_ id: String) -> String { "device-token." + id }
    }

    private let defaults: SimpleDefaults
    private let secrets: SecretStore

    @Published public private(set) var servers: [SavedServer] = []
    @Published public private(set) var activeID: String?
    @Published public var deviceName: String { didSet { defaults.set(deviceName, for: Key.deviceName) } }
    @Published public var autoStartCall: Bool { didSet { defaults.set(autoStartCall, for: Key.autoStart) } }
    @Published public var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, for: Key.keepAwake) } }
    @Published public var haptics: Bool { didSet { defaults.set(haptics, for: Key.haptics) } }
    /// Live work view: full (cards out of the core), minimal (one ticker line), off. Like the browser's rail button.
    @Published public var execLevel: ExecLevel { didSet { defaults.set(execLevel.rawValue, for: Key.execLevel) } }
    /// Tell Jarvis what this screen shows (`screen_state`), so debriefs and short briefings are delivered to the phone.
    @Published public var sendScreenState: Bool { didSet { defaults.set(sendScreenState, for: Key.screenState) } }
    /// Visual effects: "auto" (follows Reduce Motion / Low Power Mode), "full" or "calm".
    @Published public var effects: String { didSet { defaults.set(effects, for: Key.effects) } }
    /// Show live execution status outside the app (Live Activity / picture-in-picture), when available.
    @Published public var liveExecution: Bool { didSet { defaults.set(liveExecution, for: Key.live) } }

    public init(defaults: SimpleDefaults, secrets: SecretStore, defaultDeviceName: String = "iPhone") {
        self.defaults = defaults; self.secrets = secrets
        deviceName = defaults.string(Key.deviceName) ?? defaultDeviceName
        autoStartCall = defaults.bool(Key.autoStart) ?? true
        keepScreenAwake = defaults.bool(Key.keepAwake) ?? false
        haptics = defaults.bool(Key.haptics) ?? true
        execLevel = defaults.string(Key.execLevel).flatMap(ExecLevel.init(rawValue:)) ?? .full
        sendScreenState = defaults.bool(Key.screenState) ?? true
        effects = defaults.string(Key.effects) ?? "auto"
        liveExecution = defaults.bool(Key.live) ?? false
        if let json = defaults.string(Key.servers), let list = try? JSONDecoder().decode([SavedServer].self, from: Data(json.utf8)) { servers = list }
        activeID = defaults.string(Key.activeServer)
        migrateLegacy()
        if let a = activeID, !servers.contains(where: { $0.id == a }) { activeID = servers.first?.id }
    }

    private func migrateLegacy() {
        guard let text = defaults.string(Key.endpoint), !text.isEmpty else { return }
        if let ep = try? Endpoint.parse(text) {
            let existing = servers.first { $0.endpoint == ep }
            let server = existing ?? SavedServer(name: ep.suggestedName, address: ep.canonicalText)
            if existing == nil { servers.append(server) }
            if let t = secrets.read(Key.legacyToken), secrets.read(Key.token(server.id)) == nil { _ = secrets.write(t, for: Key.token(server.id)) }
            if activeID == nil { activeID = server.id }
            persist()
        }
        secrets.delete(Key.legacyToken)
        defaults.set(nil as String?, for: Key.endpoint)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(servers), let s = String(data: d, encoding: .utf8) { defaults.set(s, for: Key.servers) }
        defaults.set(activeID, for: Key.activeServer)
    }

    // MARK: current address

    public var activeServer: SavedServer? { servers.first { $0.id == activeID } }
    public var endpoint: Endpoint? { activeServer?.endpoint }
    /// What the UI shows as "the base URL".
    public var endpointText: String { activeServer?.address ?? "" }
    public var token: String? { activeID.flatMap { token(for: $0) } }
    public var isPaired: Bool { endpoint != nil && token != nil }

    public func token(for id: String) -> String? { secrets.read(Key.token(id)) }
    public func hasToken(for id: String) -> Bool { token(for: id) != nil }
    @discardableResult public func setToken(_ token: String, for id: String) -> Bool { secrets.write(token, for: Key.token(id)) }

    // MARK: saved addresses

    /// Validates with `Endpoint.parse` and stores the canonical form. A blank name gets a suggested one.
    @discardableResult
    public func addServer(name: String, address: String, makeActive: Bool = false) throws -> SavedServer {
        let ep = try Endpoint.parse(address)
        if let dup = servers.first(where: { $0.endpoint == ep }) { throw ServerListError.duplicate(dup.name) }
        let s = SavedServer(name: cleanName(name, ep), address: ep.canonicalText)
        servers.append(s)
        if makeActive || activeID == nil { activeID = s.id }
        persist()
        return s
    }

    /// Changes the name and/or address. The token stays: editing an address does not unpair (it is the same server
    /// at a new URL, e.g. after an ngrok restart); if it is not, the connection reports unauthorized and pairing opens.
    @discardableResult
    public func updateServer(id: String, name: String, address: String) throws -> SavedServer {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { throw ServerListError.notFound }
        let ep = try Endpoint.parse(address)
        if let dup = servers.first(where: { $0.id != id && $0.endpoint == ep }) { throw ServerListError.duplicate(dup.name) }
        servers[i].name = cleanName(name, ep); servers[i].address = ep.canonicalText
        persist()
        return servers[i]
    }

    public func deleteServer(id: String) throws {
        guard servers.contains(where: { $0.id == id }) else { throw ServerListError.notFound }
        guard id != activeID else { throw ServerListError.cannotDeleteActive }
        servers.removeAll { $0.id == id }
        secrets.delete(Key.token(id))
        persist()
    }

    public func setActive(_ id: String) { guard servers.contains(where: { $0.id == id }) else { return }; activeID = id; persist() }

    private func cleanName(_ n: String, _ ep: Endpoint) -> String {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? ep.suggestedName : String(t.prefix(40))
    }

    // MARK: pairing

    /// After a successful pairing: the token belongs to the saved address with this endpoint (created if new) and it
    /// becomes the active one.
    public func savePairing(endpoint: Endpoint, token: String, deviceName: String) -> Bool {
        let server: SavedServer
        if let s = servers.first(where: { $0.endpoint == endpoint }) { server = s }
        else if let s = try? addServer(name: "", address: endpoint.canonicalText) { server = s }
        else { return false }
        guard secrets.write(token, for: Key.token(server.id)) else { return false }
        activeID = server.id
        self.deviceName = deviceName
        persist()
        return true
    }

    /// This server revoked the phone (or the owner forgot it): every saved address belongs to that server, so all tokens go; the
    /// addresses stay so pairing again is quick.
    public func forgetDevice() { for s in servers { secrets.delete(Key.token(s.id)) } }
    /// Only the token of the active address (the server answered "unpaired" there).
    public func forgetActiveToken() { if let a = activeID { secrets.delete(Key.token(a)) } }
    public func forgetEverything() { forgetDevice(); servers = []; activeID = nil; persist() }
}
