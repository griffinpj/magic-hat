//
//  ScryfallBulkClient.swift
//  magic-hat
//
//  Scryfall's bulk data manifest. Bulk is published only as line-delimited
//  `.jsonl.gz`, which is what makes an on-device catalog possible: it streams
//  a line at a time instead of needing the whole document in memory.
//
//  Card lines carry image URLs, never image bytes, so downloading the catalog
//  does not change how images are stored — they keep streaming lazily into
//  ImageLoader's disk cache.
//

import Foundation

nonisolated struct ScryfallBulkEntry: Decodable, Sendable {
    let type: String
    let name: String
    let updatedAt: String
    let compressedSize: Int?
    let jsonlDownloadURI: String?

    enum CodingKeys: String, CodingKey {
        case type, name
        case updatedAt = "updated_at"
        case compressedSize = "compressed_size"
        case jsonlDownloadURI = "jsonl_download_uri"
    }
}

nonisolated struct ScryfallBulkListResponse: Decodable, Sendable {
    let data: [ScryfallBulkEntry]
}

/// The bulk datasets we ingest.
nonisolated enum BulkDataset: String, Sendable, CaseIterable {
    /// Every printing in English — what a collection actually references.
    case defaultCards = "default_cards"
    /// All rulings, keyed by oracle id. Small, so we always take it.
    case rulings = "rulings"

    var displayName: String {
        switch self {
        case .defaultCards: return "card catalog"
        case .rulings: return "rulings"
        }
    }
}

nonisolated struct ScryfallBulkClient {
    static let shared = ScryfallBulkClient()

    private let baseURL = URL(string: "https://api.scryfall.com")!
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// GET /bulk-data — the manifest. Tiny; check `updatedAt` against what we
    /// last ingested before committing to a large download.
    func manifest() async throws -> [ScryfallBulkEntry] {
        let url = baseURL.appendingPathComponent("bulk-data")
        return try await http.request(
            ScryfallBulkListResponse.self, url: url, rateLimit: .other
        ).data
    }

    func entry(for dataset: BulkDataset) async throws -> ScryfallBulkEntry? {
        try await manifest().first { $0.type == dataset.rawValue }
    }
}

/// One line of the `rulings` bulk file.
nonisolated struct ScryfallRulingLine: Decodable, Sendable {
    let oracleId: String?
    let source: String?
    let publishedAt: String?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case source, comment
        case oracleId = "oracle_id"
        case publishedAt = "published_at"
    }
}
