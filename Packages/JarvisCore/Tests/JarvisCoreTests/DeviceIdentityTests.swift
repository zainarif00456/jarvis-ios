import XCTest
@testable import JarvisCore

final class DeviceIdentityTests: XCTestCase {
    private func sample(name: String = "Zain's iPhone", network: DeviceIdentity.Network = .cellular) -> DeviceIdentity {
        DeviceIdentity(installID: "ABC-123", model: "iPhone14,3", name: name, os: "iOS 27.2", appVersion: "1.0", network: network)
    }

    override func tearDown() { DeviceIdentity.publish(nil) }

    func testHeadersDescribeTheDevice() {
        let h = sample().headers(route: "Tailscale")
        XCTAssertEqual(h["X-Jarvis-Client"], "ios-app")
        XCTAssertEqual(h["X-Jarvis-Install"], "ABC-123")
        XCTAssertEqual(h["X-Jarvis-Device-Model"], "iPhone14,3")
        XCTAssertEqual(h["X-Jarvis-OS"], "iOS 27.2")
        XCTAssertEqual(h["X-Jarvis-Network"], "cellular")
        XCTAssertEqual(h["X-Jarvis-Route"], "Tailscale")
    }

    func testHeaderValuesAreAsciiAndOneLine() {
        let h = sample(name: "Zain\u{2019}s \u{1F4F1}\nphone").headers(route: nil)
        for (_, v) in h {
            XCTAssertTrue(v.allSatisfy { $0.isASCII && $0 != "\n" && $0 != "\r" }, v)
        }
        XCTAssertNil(h["X-Jarvis-Route"])
        XCTAssertEqual(h["X-Jarvis-Device-Name"]?.removingPercentEncoding, "Zain\u{2019}s \u{1F4F1}\nphone".trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testRequestsCarryThePublishedIdentity() throws {
        let e = try Endpoint.parse("my-laptop.tail1234.ts.net")
        XCTAssertNil(e.requestHeaders(token: "t")["X-Jarvis-Install"])        // nothing published yet: unchanged
        DeviceIdentity.publish(sample(network: .wifi))
        let h = e.requestHeaders(token: "t")
        XCTAssertEqual(h["X-Jarvis-Install"], "ABC-123")
        XCTAssertEqual(h["X-Jarvis-Network"], "wifi")
        XCTAssertEqual(h["X-Jarvis-Route"], "Tailscale")
        XCTAssertEqual(h["Cookie"], "jarvis_device=t")                       // existing headers untouched
        XCTAssertEqual(h["Origin"], e.origin)
    }
}
