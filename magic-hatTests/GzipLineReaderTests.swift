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

    /// A gzip file from raw DEFLATE (Apple's `.zlib` is RFC 1951) wrapped in
    /// a minimal header and a zeroed trailer — the reader never checks the CRC.
    private func gzip(_ body: Data) throws -> Data {
        let deflated = try (body as NSData).compressed(using: .zlib) as Data
        var file = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        file.append(deflated)
        file.append(Data(count: 8))
        return file
    }

    private func syntheticLines(_ count: Int) -> [String] {
        // Lines of uneven length (some far longer than a tiny chunk, some
        // empty) so boundaries land everywhere in the inflated buffer.
        (0..<count).map { i in
            i % 97 == 0 ? "" : "{\"i\":\(i),\"name\":\"" + String(repeating: "x", count: (i * 37) % 900) + "\"}"
        }
    }

    /// Several MB across thousands of lines: the cursor and the once-per-
    /// inflate compaction must hand back exactly what went in, whatever the
    /// chunk size, including a final line with no newline.
    @Test func multiMegabyteFileReadsBackIdentically() throws {
        let expected = syntheticLines(12_000)
        let body = Data(expected.joined(separator: "\n").utf8)
        #expect(body.count > 4_000_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try gzip(body).write(to: url)
        for chunk in [1_000, 64 * 1024, 256 * 1024] {
            let out = try lines(url, chunk: chunk)
            #expect(out.count == expected.count)
            #expect(out == expected)
        }
    }

    /// A download cut short: the reader returns what it can and then throws,
    /// rather than spinning forever on a partial last line.
    @Test func truncatedFileThrowsInsteadOfLooping() throws {
        let body = Data(syntheticLines(3_000).joined(separator: "\n").utf8)
        let whole = try gzip(body)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
        try whole.prefix(whole.count / 2).write(to: url)
        let reader = try GzipLineReader(url: url, chunkSize: 4096)
        defer { reader.close() }
        var read = 0
        #expect(throws: GzipLineReader.GzipError.self) {
            while try reader.next() != nil { read += 1 }
        }
        #expect(read > 0)
        #expect(read < 3_000)
    }

    @Test func rejectsNonGzip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not gzip at all".utf8).write(to: url)
        #expect(throws: GzipLineReader.GzipError.self) { _ = try GzipLineReader(url: url) }
    }
}
