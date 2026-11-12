import Foundation

/// A `multipart/form-data` body written to a temporary file (so a 100 MB upload never sits in memory).
public enum Multipart {
    public struct Written { public let bodyURL: URL; public let contentType: String; public let length: Int64 }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    public static func write(fileURL: URL, fieldName: String, fileName: String, mime: String, fields: [String: String], boundary: String = "JarvisBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> Written {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        var total: Int64 = 0
        func put(_ s: String) throws { let d = Data(s.utf8); try w.write(contentsOf: d); total += Int64(d.count) }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(k))\"\r\n\r\n\(v)\r\n")
        }
        try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(fieldName))\"; filename=\"\(escape(fileName))\"\r\nContent-Type: \(mime)\r\n\r\n")
        let r = try FileHandle(forReadingFrom: fileURL)
        defer { try? r.close() }
        while true {
            let chunk = try r.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try w.write(contentsOf: chunk); total += Int64(chunk.count)
        }
        try put("\r\n--\(boundary)--\r\n")
        return Written(bodyURL: out, contentType: "multipart/form-data; boundary=\(boundary)", length: total)
    }
}
