//
//  ZipArchive.swift
//  magic-hat
//
//  A small zip writer and reader for backups — enough of PKWARE's format
//  (APPNOTE 6.3) for a flat archive of a few files: local headers, deflate
//  or stored entries, a central directory, no zip64, no encryption. iOS
//  has no public zip API; the Compression framework's COMPRESSION_ZLIB is
//  raw DEFLATE (RFC 1951), which is exactly what a zip entry holds (the
//  same fact GzipLineReader leans on), and CRC-32 is a table.
//
//  Reading accepts what the writer makes and what Finder, `zip` and
//  NSFileCoordinator's `.forUploading` make (deflate or stored, sizes in
//  the central directory), so a backup a user re-zipped still restores.
//  Pure and nonisolated: it runs wherever the backup does.
//

import Foundation
import Compression

nonisolated enum ZipError: Error, LocalizedError, Equatable {
    case notAZip
    case unsupported(String)
    case corrupt(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "The file isn't a zip archive."
        case .unsupported(let what): return "The archive uses \(what), which the app can't read."
        case .corrupt(let name): return "\(name) in the archive is damaged."
        case .missing(let name): return "The archive has no \(name)."
        }
    }
}

nonisolated struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0
    private let date: Date

    init(date: Date = Date()) { self.date = date }

    /// Adds a file. Deflated when that is smaller, stored otherwise.
    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let deflated = Deflate.compress(data)
        let useDeflate = deflated.map { $0.count < data.count } ?? false
        let payload = useDeflate ? deflated! : data
        let method: UInt16 = useDeflate ? 8 : 0
        let (dosTime, dosDate) = Self.dosDateTime(date)
        let offset = UInt32(body.count)

        var local = Data()
        local.append(le32: 0x04034b50)
        local.append(le16: 20)                 // version needed
        local.append(le16: 0x0800)             // UTF-8 names
        local.append(le16: method)
        local.append(le16: dosTime)
        local.append(le16: dosDate)
        local.append(le32: crc)
        local.append(le32: UInt32(payload.count))
        local.append(le32: UInt32(data.count))
        local.append(le16: UInt16(name.count))
        local.append(le16: 0)                  // extra
        local.append(name)
        body.append(local)
        body.append(payload)

        var entry = Data()
        entry.append(le32: 0x02014b50)
        entry.append(le16: 0x031E)             // made by: Unix, 3.0
        entry.append(le16: 20)
        entry.append(le16: 0x0800)
        entry.append(le16: method)
        entry.append(le16: dosTime)
        entry.append(le16: dosDate)
        entry.append(le32: crc)
        entry.append(le32: UInt32(payload.count))
        entry.append(le32: UInt32(data.count))
        entry.append(le16: UInt16(name.count))
        entry.append(le16: 0)                  // extra
        entry.append(le16: 0)                  // comment
        entry.append(le16: 0)                  // disk
        entry.append(le16: 0)                  // internal attributes
        entry.append(le32: 0o100644 << 16)     // external: -rw-r--r--
        entry.append(le32: offset)
        entry.append(name)
        central.append(entry)
        count += 1
    }

    /// The archive: every entry, the central directory, its end record.
    func finish() -> Data {
        var out = body
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x06054b50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: count)
        out.append(le16: count)
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let date: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }
}

nonisolated struct ZipReader {
    struct Entry: Sendable {
        let path: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    let entries: [Entry]
    private let data: Data

    init(_ data: Data) throws {
        self.data = data
        // The end-of-central-directory record: within the last 64KB + 22.
        guard data.count >= 22 else { throw ZipError.notAZip }
        var eocd: Int?
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 0xFFFF)
        while i >= floor {
            if data.le32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        let total = Int(data.le16(at: eocd + 10))
        let centralSize = Int(data.le32(at: eocd + 12))
        let centralOffset = Int(data.le32(at: eocd + 16))
        if centralOffset == 0xFFFFFFFF || total == 0xFFFF { throw ZipError.unsupported("zip64") }
        guard centralOffset + centralSize <= data.count else { throw ZipError.notAZip }

        var entries: [Entry] = []
        var p = centralOffset
        for _ in 0..<total {
            guard p + 46 <= data.count, data.le32(at: p) == 0x02014b50 else { throw ZipError.corrupt("The directory") }
            let flags = data.le16(at: p + 8)
            if flags & 0x1 != 0 { throw ZipError.unsupported("encryption") }
            let method = data.le16(at: p + 10)
            let crc = data.le32(at: p + 16)
            let compressed = Int(data.le32(at: p + 20))
            let size = Int(data.le32(at: p + 24))
            let nameLength = Int(data.le16(at: p + 28))
            let extraLength = Int(data.le16(at: p + 30))
            let commentLength = Int(data.le16(at: p + 32))
            let offset = Int(data.le32(at: p + 42))
            guard p + 46 + nameLength <= data.count else { throw ZipError.corrupt("The directory") }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(path: name, method: method, crc: crc, compressedSize: compressed, size: size, localOffset: offset))
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The entry at `path`, or the one whose last component is `path`
    /// (a re-zipped backup nests its files in a folder).
    func entry(named path: String) -> Entry? {
        entries.first { $0.path == path }
            ?? entries.first { !$0.path.hasPrefix("__MACOSX/") && ($0.path as NSString).lastPathComponent == path }
    }

    func data(for path: String) throws -> Data {
        guard let entry = entry(named: path) else { throw ZipError.missing(path) }
        let p = entry.localOffset
        guard p + 30 <= data.count, data.le32(at: p) == 0x04034b50 else { throw ZipError.corrupt(path) }
        let nameLength = Int(data.le16(at: p + 26))
        let extraLength = Int(data.le16(at: p + 28))
        let start = p + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt(path) }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        let out: Data
        switch entry.method {
        case 0: out = payload
        case 8:
            guard let inflated = Deflate.decompress(payload, size: entry.size) else { throw ZipError.corrupt(path) }
            out = inflated
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard out.count == entry.size, CRC32.checksum(out) == entry.crc else { throw ZipError.corrupt(path) }
        return out
    }
}

// MARK: - Deflate and CRC-32

nonisolated enum Deflate {
    /// Raw DEFLATE, or nil if it didn't fit (incompressible input can grow).
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    static func decompress(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        return out
    }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private nonisolated extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    func le16(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func le32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
}
