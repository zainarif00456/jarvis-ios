import XCTest
import JarvisCore
@testable import JarvisNet

final class MultipartTests: XCTestCase {
    func testBodyLayoutAndLength() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("mp-src-\(UUID().uuidString).bin")
        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        try payload.write(to: src); defer { try? FileManager.default.removeItem(at: src) }
        let w = try Multipart.write(fileURL: src, fieldName: "file", fileName: "a\"b.bin", mime: "application/octet-stream", fields: ["source": "my phone", "origin": "device"], boundary: "BND")
        defer { try? FileManager.default.removeItem(at: w.bodyURL) }
        let body = try Data(contentsOf: w.bodyURL)
        XCTAssertEqual(Int64(body.count), w.length)
        XCTAssertEqual(w.contentType, "multipart/form-data; boundary=BND")
        let head = String(decoding: body.prefix(400), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("--BND\r\nContent-Disposition: form-data; name=\"origin\"\r\n\r\ndevice\r\n"))
        XCTAssertTrue(head.contains("name=\"file\"; filename=\"a%22b.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"))
        XCTAssertTrue(String(decoding: body.suffix(20), as: UTF8.self).hasSuffix("\r\n--BND--\r\n"))
        XCTAssertNotNil(body.range(of: payload), "the file bytes are inside, unchanged")
    }
    func testErrorDetailParsing() {
        XCTAssertEqual(ApiClient.detail(from: Data(#"{"detail":"that code is invalid, used or expired"}"#.utf8)), "that code is invalid, used or expired")
        XCTAssertEqual(ApiClient.detail(from: Data(#"{"detail":[{"msg":"too short"},{"msg":"bad"}]}"#.utf8)), "too short; bad")
        XCTAssertEqual(ApiClient.detail(from: Data("<html>".utf8)), "")
        XCTAssertTrue(ApiError.offline("x").isTransient); XCTAssertTrue(ApiError.http(status: 503, detail: "").isTransient)
        XCTAssertFalse(ApiError.http(status: 400, detail: "").isTransient); XCTAssertTrue(ApiError.http(status: 401, detail: "").isUnauthorized)
    }
}
