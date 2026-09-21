import Testing
import Foundation
@testable import magic_hat

@Suite("GzipLineReader")
struct GzipLineReaderTests {
    // gzip("{\"n\":1}\n{\"n\":2}\n{\"n\":3}")  — no trailing newline
    private let plain = "H4sIAAAAAAAC/6tWylOyMqzlqgbRRlDauBYA86skKxcAAAA="
    // gzip with an FNAME header field and a blank line in the body
    private let named = "H4sICAAAAAAC/2NhcmRzLmpzb25sAKtWSlSyUqpQquXiqgYzK4FMAEJgoicVAAAA"

    private func write(_ base64: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try Data(base64Encoded: base64)!.write(to: url)
        return url
    }

    private func lines(_ url: URL, chunk: Int) throws -> [String] {
        let reader = try GzipLineReader(url: url, chunkSize: chunk)
        defer { reader.close() }
        var out: [String] = []
        while let line = try reader.next() { out.append(String(decoding: line, as: UTF8.self)) }
        return out
    }

    @Test func readsEveryLineIncludingUnterminatedTail() throws {
        let out = try lines(write(plain), chunk: 256 * 1024)
        #expect(out == ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"])
    }

    /// Tiny chunk forces many inflate rounds and line boundaries that fall
    /// mid-chunk — the streaming path the 79MB catalog actually exercises.
    @Test func tinyChunksProduceIdenticalOutput() throws {
        #expect(try lines(write(plain), chunk: 4) == ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"])
    }

    @Test func skipsFnameHeaderAndBlankLines() throws {
        let out = try lines(write(named), chunk: 8).filter { !$0.isEmpty }
        #expect(out == ["{\"a\":\"x\"}", "{\"a\":\"y\"}"])
    }

    @Test func rejectsNonGzip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not gzip at all".utf8).write(to: url)
        #expect(throws: GzipLineReader.GzipError.self) { _ = try GzipLineReader(url: url) }
    }
}
