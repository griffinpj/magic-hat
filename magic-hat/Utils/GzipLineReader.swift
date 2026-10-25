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

    /// Inflated bytes; everything before `cursor` has been returned as lines.
    /// Lines are read by moving the cursor, and the consumed head is dropped
    /// once per `inflateMore` — by then only a partial line is left, so the
    /// compaction moves a few hundred bytes. It used to `removeSubrange` each
    /// line off the front, moving the whole buffered tail (1–4MB) per line.
    /// Measured (-O, M-series Mac, best of 5, whole file read): the 2.2MB
    /// `default_cards` slice 110ms → 12ms, the 0.5MB rulings slice 67ms → 3ms.
    private var pending = Data()
    private var cursor = 0
    /// Where the newline search resumes: bytes before it (from `cursor`) are
    /// known to hold none, so a long line split across inflates is scanned once.
    private var scanned = 0
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
                guard cursor < pending.count else { return nil }
                let rest = pending.subdata(in: cursor..<pending.count)
                pending = Data()
                cursor = 0
                scanned = 0
                return rest
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
        let count = pending.count
        let from = max(cursor, scanned)
        guard from < count else { return nil }
        // memchr over the bytes rather than `Data.firstIndex(of:)`, which
        // walks them through the generic Collection path one at a time.
        let found: Int? = pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let hit = memchr(base + from, 0x0A, count - from) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        guard let newline = found else {
            scanned = count
            return nil
        }
        let line = pending.subdata(in: cursor..<newline)
        cursor = newline + 1
        scanned = cursor
        return line
    }

    /// Drops the lines already returned, so `pending` holds only the
    /// unfinished one before more is appended.
    private func compact() {
        guard cursor > 0 else { return }
        // `subdata`, not `removeSubrange`: a new zero-based buffer, so the
        // offsets above stay offsets from `startIndex == 0`.
        pending = cursor >= pending.count ? Data() : pending.subdata(in: cursor..<pending.count)
        scanned -= cursor
        cursor = 0
    }

    private func inflateMore() throws {
        compact()
        if carry.isEmpty && !reachedEOF {
            if let next = try handle.read(upToCount: chunkSize), !next.isEmpty {
                carry = next
            } else {
                reachedEOF = true
            }
        }

        var status = COMPRESSION_STATUS_OK
        var producedAny = false
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
                if produced > 0 {
                    pending.append(outBuffer, count: produced)
                    producedAny = true
                }
            } while stream.pointee.src_size > 0 && status == COMPRESSION_STATUS_OK
        }

        carry = Data()
        if status == COMPRESSION_STATUS_END {
            finished = true
        } else if reachedEOF && !producedAny {
            // The file ended before the DEFLATE stream did (a download cut
            // short): FINALIZE with no input returns OK and nothing more,
            // forever. With a partial last line buffered this used to loop
            // in `next()` without end; a cut-off catalog is an error, not
            // a shorter one.
            throw GzipError.truncated
        }
    }
}
