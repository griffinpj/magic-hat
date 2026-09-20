//
//  RateLimiter.swift
//  magic-hat
//
//  Per-category request throttle. Scryfall publishes hard rate limits per
//  endpoint family; this actor serializes requests within a category and
//  spaces them by a minimum interval. Lives in Utils so client code stays
//  focused on API shape, not pacing.
//

import Foundation

/// Scryfall endpoint families and their minimum spacing between requests.
nonisolated enum RateLimitCategory {
    case cardsSearch    // /cards/search      2/sec
    case cardsNamed     // /cards/named       2/sec
    case cardsRandom    // /cards/random      2/sec
    case cardsCollection // /cards/collection 2/sec
    case cardsManifest  // /cards/manifest    10/min
    case other          // everything else    10/sec

    /// Minimum interval between consecutive requests, in seconds.
    var minInterval: TimeInterval {
        switch self {
        case .cardsSearch, .cardsNamed, .cardsRandom, .cardsCollection:
            return 0.5      // 2 per second
        case .cardsManifest:
            return 6.0      // 10 per minute
        case .other:
            return 0.1      // 10 per second
        }
    }
}

/// Serializes and paces work per category. Callers `await limiter.wait(for:)`
/// immediately before issuing a request.
actor RateLimiter {
    static let shared = RateLimiter()

    private var lastStart: [String: Date] = [:]

    private func key(_ category: RateLimitCategory) -> String {
        "\(category)"
    }

    /// Suspends until it is safe to start a request in `category`, then
    /// reserves that slot. Concurrent callers queue on the actor and are
    /// spaced by `minInterval`.
    func wait(for category: RateLimitCategory) async {
        let k = key(category)
        let interval = category.minInterval
        let now = Date()

        if let last = lastStart[k] {
            let earliest = last.addingTimeInterval(interval)
            if earliest > now {
                let delay = earliest.timeIntervalSince(now)
                // Reserve the slot up front so queued callers space correctly.
                lastStart[k] = earliest
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return
            }
        }
        lastStart[k] = now
    }
}
