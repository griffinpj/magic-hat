//
//  CardRuling.swift
//  magic-hat
//
//  An official ruling, keyed by oracle id (rulings apply to a card, not to a
//  particular printing). Ingested from Scryfall's `rulings` bulk file, which
//  is small enough (~5MB) that we always take it — it makes the detail
//  screen's Rulings tab work offline and without a per-card request.
//

import Foundation
import SwiftData
import CryptoKit

@Model
nonisolated final class CardRuling {
    /// Stable identity so re-ingesting the bulk file updates rather than
    /// duplicates: oracle id + source + date + the text itself.
    @Attribute(.unique) var id: String

    // Every lookup is "rulings for this oracle id" against a table that will
    // hold the whole catalog's rulings.
    #Index<CardRuling>([\.oracleID])

    var oracleID: String
    var source: String
    var publishedAt: String
    var comment: String

    init(oracleID: String, source: String, publishedAt: String, comment: String) {
        // SHA256, not hashValue: Swift's hashValue is seeded per process, so
        // re-ingesting would mint new ids every launch and duplicate rows.
        let digest = SHA256.hash(data: Data(comment.utf8))
        let commentKey = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        self.id = "\(oracleID)|\(source)|\(publishedAt)|\(commentKey)"
        self.oracleID = oracleID
        self.source = source
        self.publishedAt = publishedAt
        self.comment = comment
    }
}
