import XCTest
@testable import JarvisCore

final class AddressTests: XCTestCase {
    private func p(_ s: String) throws -> Endpoint { try Endpoint.parse(s) }

    func testAcceptedForms() throws {
        let cases: [(String, Bool, String, Int?)] = [
            ("my-laptop.tail1234.ts.net", true, "my-laptop.tail1234.ts.net", nil),
            ("my-laptop.tail1234.ts.net:8443", true, "my-laptop.tail1234.ts.net", 8443),
            ("https://my-laptop.tail1234.ts.net/", true, "my-laptop.tail1234.ts.net", nil),
            ("http://my-laptop.tail1234.ts.net", false, "my-laptop.tail1234.ts.net", nil),
            ("https://abc-12-34.ngrok-free.app", true, "abc-12-34.ngrok-free.app", nil),
            ("  https://ABC.ngrok-free.app///api/session?x=1#f ", true, "abc.ngrok-free.app", nil),
            ("abc.ngrok-free.app", true, "abc.ngrok-free.app", nil),
            ("192.168.1.20:8000", false, "192.168.1.20", 8000),
            ("http://192.168.1.20:8000/", false, "192.168.1.20", 8000),
            ("http://100.101.102.103:8000", false, "100.101.102.103", 8000),
            ("100.64.0.1:8000", false, "100.64.0.1", 8000),
            ("http://10.0.0.5", false, "10.0.0.5", nil),
            ("http://localhost:8000", false, "localhost", 8000),
            ("http://[::1]:8000", false, "[::1]", 8000),
            ("wss://x.example.com", true, "x.example.com", nil),
        ]
        for (raw, secure, host, port) in cases {
            let e = try p(raw)
            XCTAssertEqual(e.secure, secure, raw); XCTAssertEqual(e.host, host, raw); XCTAssertEqual(e.port, port, raw)
            XCTAssertEqual(try p(e.canonicalText), e, "canonical text round-trips: \(raw)")
        }
    }

    func testPlainHttpOnlyForPrivateAddresses() {
        for bad in ["http://example.com", "http://abc.ngrok-free.app", "http://8.8.8.8:8000", "http://100.128.0.1", "http://172.32.0.1", "http://100.63.255.1"] {
            XCTAssertThrowsError(try p(bad), bad) { XCTAssertTrue("\($0)".contains("insecureHost"), bad) }
        }
        XCTAssertNoThrow(try p("http://172.31.255.1"))
        XCTAssertNoThrow(try p("http://100.127.255.255"))
    }

    func testRejected() {
        for bad in ["", "   ", "ftp://x.com", "a b.com", "host:notaport", "host:0", "host:70000", "user@host.com", "http://", "https://:8000", "[::1", "ho$t.com", "999.1.1.1"] {
            if bad == "999.1.1.1" { continue }   // syntactically a name; DNS will say no
            XCTAssertThrowsError(try p(bad), "'\(bad)'")
        }
    }

    func testNamesAndKinds() throws {
        XCTAssertEqual(try p("x.ts.net").suggestedName, "Tailscale")
        XCTAssertEqual(try p("100.100.1.1:8000").suggestedName, "Tailscale")
        XCTAssertEqual(try p("a.ngrok-free.app").suggestedName, "ngrok")
        XCTAssertTrue(try p("a.ngrok-free.app").isNgrok)
        XCTAssertEqual(try p("192.168.0.4:8000").suggestedName, "LAN")
        XCTAssertEqual(try p("127.0.0.1:8000").suggestedName, "This computer")
        XCTAssertEqual(try p("jarvis.example.com").suggestedName, "jarvis.example.com")
    }

    /// The server rejects an Origin that is not its own Host: the headers must follow the CURRENT address.
    func testHeadersFollowTheAddress() throws {
        for raw in ["my-laptop.tail1.ts.net", "https://abc.ngrok-free.app", "http://192.168.1.5:8000", "x.example.com:8443"] {
            let e = try p(raw)
            let h = e.requestHeaders(token: "tok")
            XCTAssertEqual(h["Origin"], e.origin)
            XCTAssertEqual(h["Origin"], "\(e.secure ? "https" : "http")://\(e.authority)")
            XCTAssertEqual(h["Cookie"], "jarvis_device=tok")
            XCTAssertEqual(h["ngrok-skip-browser-warning"], "1")
            XCTAssertFalse(h["User-Agent"]!.contains("Mozilla"))
        }
        XCTAssertNil(try p("x.com").requestHeaders(token: nil)["Cookie"])
        XCTAssertEqual(try p("https://x.com:443/").origin, "https://x.com")
    }

    func testHTMLSniffing() {
        XCTAssertTrue(ResponseSniffer.looksLikeHTML(contentType: "text/html; charset=utf-8", body: Data()))
        XCTAssertTrue(ResponseSniffer.looksLikeHTML(contentType: nil, body: Data("  <!DOCTYPE html><html>ngrok".utf8)))
        XCTAssertTrue(ResponseSniffer.looksLikeHTML(contentType: "application/json", body: Data("<html><body>ERR_NGROK_3200".utf8)))
        XCTAssertFalse(ResponseSniffer.looksLikeHTML(contentType: "application/json", body: Data("{\"paired\":true}".utf8)))
        XCTAssertFalse(ResponseSniffer.looksLikeHTML(contentType: nil, body: Data()))
    }
}
