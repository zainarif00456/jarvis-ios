import XCTest
import JarvisCore
import JarvisNet
@testable import JarvisModel

@MainActor
final class AddressFlowTests: XCTestCase {
    func store(_ secrets: MemorySecretStore = MemorySecretStore(), _ defaults: MemoryDefaults = MemoryDefaults()) -> SettingsStore {
        SettingsStore(defaults: defaults, secrets: secrets)
    }

    func testLegacySingleAddressIsMigrated() {
        let secrets = MemorySecretStore(), defaults = MemoryDefaults()
        _ = secrets.write("oldtoken", for: "device-token"); defaults.set("http://192.168.1.5:8000", for: "endpoint")
        let s = store(secrets, defaults)
        XCTAssertEqual(s.servers.count, 1)
        XCTAssertEqual(s.servers[0].name, "LAN")
        XCTAssertEqual(s.endpoint?.authority, "192.168.1.5:8000")
        XCTAssertEqual(s.token, "oldtoken")
        XCTAssertNil(secrets.read("device-token"), "legacy key removed")
        XCTAssertNil(defaults.string("endpoint"))
        // survives a relaunch
        let again = store(secrets, defaults)
        XCTAssertEqual(again.servers, s.servers); XCTAssertEqual(again.token, "oldtoken")
    }

    func testAddEditDeleteSwitchActive() throws {
        let s = store()
        let a = try s.addServer(name: "Tailscale", address: "my-laptop.tail1.ts.net")
        XCTAssertEqual(s.activeID, a.id, "first address becomes active")
        let b = try s.addServer(name: "", address: "https://abc.ngrok-free.app/")
        XCTAssertEqual(b.name, "ngrok"); XCTAssertEqual(b.address, "https://abc.ngrok-free.app")
        XCTAssertThrowsError(try s.addServer(name: "dup", address: "ABC.ngrok-free.app")) { XCTAssertEqual($0 as? ServerListError, .duplicate("ngrok")) }
        XCTAssertThrowsError(try s.addServer(name: "bad", address: "http://example.com"))
        _ = try s.updateServer(id: b.id, name: "ngrok", address: "https://def.ngrok-free.app")
        XCTAssertEqual(s.servers[1].address, "https://def.ngrok-free.app")
        XCTAssertThrowsError(try s.deleteServer(id: a.id)) { XCTAssertEqual($0 as? ServerListError, .cannotDeleteActive) }
        s.setActive(b.id)
        try s.deleteServer(id: a.id)
        XCTAssertEqual(s.servers.map(\.id), [b.id])
    }

    func testTokensArePerAddressAndForgetting() throws {
        let secrets = MemorySecretStore()
        let s = store(secrets)
        let a = try s.addServer(name: "A", address: "a.ts.net"), b = try s.addServer(name: "B", address: "b.example.com")
        XCTAssertTrue(s.savePairing(endpoint: a.endpoint!, token: "T", deviceName: "Phone"))
        XCTAssertEqual(s.token, "T"); XCTAssertNil(s.token(for: b.id))
        s.setToken("T", for: b.id)
        s.forgetActiveToken()
        XCTAssertNil(s.token(for: a.id)); XCTAssertEqual(s.token(for: b.id), "T")
        s.forgetDevice()
        XCTAssertNil(s.token(for: b.id)); XCTAssertEqual(s.servers.count, 2, "addresses stay")
        // pairing on an unknown address creates a named entry and activates it
        XCTAssertTrue(s.savePairing(endpoint: try Endpoint.parse("https://zz.ngrok-free.app"), token: "N", deviceName: "Phone"))
        XCTAssertEqual(s.activeServer?.name, "ngrok"); XCTAssertEqual(s.token, "N")
    }

    func testSwitchWithoutAnyTokenOpensPairingForThatAddress() async throws {
        let rig = Rig(paired: false)
        let m = rig.model()
        let a = try m.settings.addServer(name: "LAN", address: "http://127.0.0.1:9")
        let out = await m.switchTo(a.id)
        XCTAssertEqual(out, .needsPairing)
        XCTAssertEqual(m.phase, .needsPairing); XCTAssertEqual(m.pairingTarget?.id, a.id)
    }

    func testSwitchToUnreachableAddressStaysPut() async throws {
        let rig = Rig()                                  // paired on http://127.0.0.1:9 (nothing listens there)
        let m = rig.model()
        let old = m.settings.activeID
        let b = try m.settings.addServer(name: "other", address: "http://127.0.0.1:19")
        let out = await m.switchTo(b.id)
        guard case .failed = out else { return XCTFail("\(out)") }
        XCTAssertEqual(m.settings.activeID, old, "a failed switch changes nothing")
        let probe = await m.testConnection(address: "http://127.0.0.1:19")
        guard case .unreachable = probe else { return XCTFail("\(probe)") }
        let bad = await m.testConnection(address: "http://example.com")
        guard case .unreachable(let why) = bad else { return XCTFail() }
        XCTAssertTrue(why.contains("https"))
    }
}
