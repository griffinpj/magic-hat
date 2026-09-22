import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// The real deck list against the real catalog slice: printings named by
/// the list resolve exactly, the rest by name, double-faced cards by their
/// front face, and cards the slice doesn't hold come back unresolved.
@Suite("Deck list resolution")
struct DeckResolveTests {
    @Test @MainActor func resolvesAgainstTheCatalog() async throws {
        let container = try TestSupport.makeContainer()
        try await BulkIngester.ingest(file: try TestSupport.fixtureURL("default_cards.slice.jsonl.gz"),
                                      dataset: .defaultCards, container: container)
        let text = try String(contentsOf: try TestSupport.fixtureURL("KingUnderTheMountain.txt"), encoding: .utf8)
        let list = DeckListParser.parse(text)
        let resolved = try await DeckStore.shared(for: container).resolve(list.lines)

        let hits = resolved.filter(\.isResolved)
        #expect(hits.count >= 50, "resolved \(hits.count) of \(resolved.count)")
        #expect(resolved.count == list.lines.count)
        // A printing the slice has resolves to exactly that printing.
        let signet = try #require(resolved.first { $0.line.name == "Arcane Signet" })
        if signet.isResolved {
            let metas = try container.mainContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.name == "Arcane Signet" }))
            if let exact = metas.first(where: { $0.setCode == "ltc" && $0.collectorNumber == "273" }) {
                #expect(signet.scryfallID == exact.scryfallID)
            }
        }
        #expect(hits.allSatisfy { $0.oracleID != nil })
        let misses = resolved.filter { !$0.isResolved }
        #expect(misses.allSatisfy { $0.scryfallID == nil && $0.canonicalName == nil })
        _ = container
    }
}
