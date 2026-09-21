//
//  GzipLineReader.swift
//  magic-hat
//
//  Pull-based reader over a gzipped, line-delimited file (Scryfall publishes
//  bulk data as `.jsonl.gz`). `next()` returns one line at a time, inflating
//  only as much as it needs, so memory stays flat no matter how big the file.
//
//  Pull rather than a callback on purpose: the caller drives, so it can decode
//  a batch off the main actor and await writing it before asking for more.
//  A push API would have to buffer everything the consumer hasn't caught up on.
//
//  Two reasons this is hand-rolled:
//   * Foundation only gunzips transparently when the server sends
//     `Content-Encoding: gzip`. These are files whose *content* is gzip, so
//     nothing decompresses them for us.
//   * Apple's Compression framework speaks raw DEFLATE, not the gzip
//     container, so the header has to be parsed and skipped by hand.
//

import Foundation
import Compression

nonisolated final class GzipLineReader {
    enum GzipError: Error {
        case notGzip
        case truncated
        case inflateFailed
    }

    private let handle: FileHandle
    private let stream: UnsafeMutablePointer<compression_stream>
    private let outBuffer: UnsafeMutablePointer<UInt8>
    private let outCapacity: Int
    private let chunkSize: Int

    private var pending = Data()      // inflated bytes not yet returned as lines
    private var carry = Data()        // compressed bytes read but not yet consumed
    private var reachedEOF = false
    private var finished = false
    private var closed = false

    init(url: URL, chunkSize: Int = 256 * 1024) throws {
        self.chunkSize = chunkSize
        self.outCapacity = chunkSize * 4
        handle = try FileHandle(forReadingFrom: url)

        // gzip container header
        guard let head = try handle.read(upToCount: 4096), head.count > 10 else {
            try? handle.close()
            throw GzipError.truncated
        }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            try? handle.close()
            throw GzipError.notGzip
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {                      // FEXTRA
            guard offset + 1 < bytes.count else { try? handle.close(); throw GzipError.truncated }
            offset += 2 + (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8))
        }
        if flags & 0x08 != 0 {                      // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {                      // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }        // FHCRC
        guard offset <= head.count else { try? handle.close(); throw GzipError.truncated }

        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            try? handle.close()
            throw GzipError.inflateFailed
        }
        outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outCapacity)
        carry = head.subdata(in: offset..<head.count)
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        compression_stream_destroy(stream)
        stream.deallocate()
        outBuffer.deallocate()
        try? handle.close()
    }

    /// The next line, or nil at end of file.
    func next() throws -> Data? {
        while true {
            if let line = takeLine() { return line }
            if finished {
                if pending.isEmpty { return nil }
                let rest = pending
                pending = Data()
                return rest.isEmpty ? nil : rest
            }
            try inflateMore()
        }
    }

    /// Up to `count` lines in one call, to amortise the cost of crossing
    /// actor boundaries when the consumer writes them somewhere.
    func nextBatch(_ count: Int) throws -> [Data] {
        var lines: [Data] = []
        lines.reserveCapacity(count)
        while lines.count < count, let line = try next() {
            lines.append(line)
        }
        return lines
    }

    private func takeLine() -> Data? {
        guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
        let line = pending.subdata(in: pending.startIndex..<newline)
        pending.removeSubrange(pending.startIndex...newline)
        return line.isEmpty ? Data() : line
    }

    private func inflateMore() throws {
        if carry.isEmpty && !reachedEOF {
            if let next = try handle.read(upToCount: chunkSize), !next.isEmpty {
                carry = next
            } else {
                reachedEOF = true
            }
        }

        var status = COMPRESSION_STATUS_OK
        try carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.pointee.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 0x1)!
            stream.pointee.src_size = carry.count

            repeat {
                stream.pointee.dst_ptr = outBuffer
                stream.pointee.dst_size = outCapacity
                status = compression_stream_process(
                    stream, reachedEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                )
                guard status != COMPRESSION_STATUS_ERROR else { throw GzipError.inflateFailed }
                let produced = outCapacity - stream.pointee.dst_size
                if produced > 0 { pending.append(outBuffer, count: produced) }
            } while stream.pointee.src_size > 0 && status == COMPRESSION_STATUS_OK
        }

        carry = Data()
        if status == COMPRESSION_STATUS_END { finished = true }
        else if reachedEOF && status == COMPRESSION_STATUS_OK && pending.isEmpty { finished = true }
    }
}
