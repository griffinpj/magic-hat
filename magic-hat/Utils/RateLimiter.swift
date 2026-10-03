//
//  RateLimiter.swift
//  magic-hat
//
//  Request pacing, in Utils so client code stays about API shape. Scryfall
//  publishes one ceiling — about ten requests a second to api.scryfall.com,
//  a 429 and then a network block past it — and asks for 50–100ms between
//  requests. This app runs at **half** of that on purpose: one phone, a
//  simulator and a test run share an IP while developing, and each used to
//  take the whole budget; a 429 arrived with "FAILURE TO ACT WILL RESULT
//  IN A NETWORK BLOCK". So:
//
//  - Every Scryfall API request, whatever its family, passes one shared
//    bucket (`scryfallAPI`, 5/sec). The families used to be paced only
//    against themselves, and search + collection + the rest added up to
//    fourteen a second.
//  - Within it the search family is 1/sec (Scryfall's 2/sec, halved), and
//    the bulk manifest 5/min.
//  - Images (`cards.scryfall.io`, a CDN outside the API limit) have their
//    own lane at 5/sec, so a scroll never starves a hydration batch.
//  - A 429 from any Scryfall host pauses *all* Scryfall traffic for
//    `Retry-After`, or 60 seconds (`backOff`). Nothing retries into it.
//
//  Other hosts (Spellbook, Recommander, EDHREC, deck sites) publish no
//  limit and get 2/sec each, unchanged.
//

import Foundation

/// Endpoint families and their minimum spacing between requests.
nonisolated enum RateLimitCategory: Hashable, Sendable {
    case cardsSearch    // /cards/search
    case cardsNamed     // /cards/named
    case cardsRandom    // /cards/random
    case cardsCollection // /cards/collection
    case cardsManifest  // /bulk-data
    case other          // every other api.scryfall.com endpoint (and MTGJSON)
    case images         // cards.scryfall.io
    case spellbook      // commanderspellbook.com — unpublished; be polite
    case recommander    // recommander.cards — unpublished; be polite
    case edhrec         // json.edhrec.com — unpublished; be polite
    case deckSite       // a deck site's list, fetched for an import

    /// Minimum interval between consecutive requests in this family.
    var minInterval: TimeInterval {
        switch self {
        case .cardsSearch, .cardsNamed, .cardsRandom, .cardsCollection:
            return 1.0      // Scryfall allows 2/sec; half of it
        case .cardsManifest:
            return 12.0     // 10/min allowed; 5/min
        case .other, .images:
            return 0.2      // 10/sec allowed; 5/sec
        case .spellbook, .recommander, .edhrec, .deckSite:
            return 0.5
        }
    }

    /// Counts against Scryfall's one API ceiling.
    var isScryfallAPI: Bool {
        switch self {
        case .cardsSearch, .cardsNamed, .cardsRandom, .cardsCollection, .cardsManifest, .other: return true
        case .images, .spellbook, .recommander, .edhrec, .deckSite: return false
        }
    }

    /// Paused by a Scryfall 429.
    var isScryfall: Bool { isScryfallAPI || self == .images }
}

/// Serializes and paces work per category and across Scryfall as a whole.
/// Callers `await limiter.wait(for:)` immediately before a request.
actor RateLimiter {
    static let shared = RateLimiter()

    /// Half of Scryfall's ten a second, for every API family together.
    static let scryfallAPIInterval: TimeInterval = 0.2
    /// What a 429 without a Retry-After costs.
    static let defaultBackOff: TimeInterval = 60

    private var lastStart: [RateLimitCategory: Date] = [:]
    private var lastScryfallAPIStart: Date?
    /// Until when Scryfall traffic waits, after a 429.
    private(set) var scryfallPausedUntil: Date?

    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void

    init(now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.now = now
        self.sleep = sleep
    }

    /// Suspends until it is safe to start a request in `category`, then
    /// reserves that slot. Concurrent callers queue on the actor and are
    /// spaced by the family's interval, and Scryfall API families by the
    /// shared interval as well; a back-off holds everything Scryfall.
    func wait(for category: RateLimitCategory) async {
        let interval = category.minInterval
        var earliest = now()
        if let last = lastStart[category] {
            earliest = max(earliest, last.addingTimeInterval(interval))
        }
        if category.isScryfallAPI, let last = lastScryfallAPIStart {
            earliest = max(earliest, last.addingTimeInterval(Self.scryfallAPIInterval))
        }
        if category.isScryfall, let paused = scryfallPausedUntil {
            if paused > earliest { earliest = paused }
            else if paused <= now() { scryfallPausedUntil = nil }
        }
        // Reserve the slot up front so queued callers space correctly.
        lastStart[category] = earliest
        if category.isScryfallAPI { lastScryfallAPIStart = earliest }
        let delay = earliest.timeIntervalSince(now())
        if delay > 0 { await sleep(delay) }
    }

    /// A 429 from Scryfall: hold every Scryfall request for `seconds`
    /// (the response's Retry-After, else `defaultBackOff`). A longer hold
    /// already in place stays.
    func backOff(seconds: TimeInterval) {
        let until = now().addingTimeInterval(max(1, seconds))
        if let current = scryfallPausedUntil, current > until { return }
        scryfallPausedUntil = until
    }

    /// Seconds left on a Scryfall pause; zero when none.
    var scryfallPauseRemaining: TimeInterval {
        guard let paused = scryfallPausedUntil else { return 0 }
        return max(0, paused.timeIntervalSince(now()))
    }

    /// Retry-After as seconds (Scryfall sends a number; the header may be a
    /// date), else the default.
    nonisolated static func retryAfter(_ header: String?) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return defaultBackOff }
        if let seconds = TimeInterval(header) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) { return max(1, date.timeIntervalSinceNow) }
        return defaultBackOff
    }
}
