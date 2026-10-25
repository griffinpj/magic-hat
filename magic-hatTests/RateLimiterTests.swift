import Testing
import Foundation
@testable import magic_hat

/// The pacing Scryfall's warning made strict: one shared bucket for every
/// API family at half the published ceiling, families halved inside it,
/// images on their own lane, and a 429 holding everything Scryfall.
@Suite("RateLimiter")
struct RateLimiterTests {
    /// A limiter on a fake clock: every sleep advances it and is recorded.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        var slept: [TimeInterval] = []
        let lock = NSLock()
        func time() -> Date { lock.lock(); defer { lock.unlock() }; return now }
        func sleep(_ s: TimeInterval) { lock.lock(); slept.append(s); now = now.addingTimeInterval(s); lock.unlock() }
    }

    private func approx(_ a: [TimeInterval], _ b: [TimeInterval]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
    }

    private func make() -> (RateLimiter, Clock) {
        let clock = Clock()
        let limiter = RateLimiter(now: { clock.time() }, sleep: { clock.sleep($0) })
        return (limiter, clock)
    }

    @Test func everyAPIFamilySharesOneBucketAtHalfTheCeiling() async {
        let (limiter, clock) = make()
        await limiter.wait(for: .other)
        await limiter.wait(for: .cardsSearch)
        await limiter.wait(for: .other)
        await limiter.wait(for: .cardsCollection)
        // Four API requests: the shared 0.2s between each, whatever the family.
        #expect(approx(clock.slept, [0.2, 0.2, 0.2]), "\(clock.slept)")
        // The search family itself waits a full second from its last: it
        // started at 0.2s, the clock is at 0.6s, so 0.6s more.
        await limiter.wait(for: .cardsSearch)
        #expect(clock.slept.last.map { abs($0 - 0.6) < 0.001 } == true, "1s after the search, \(clock.slept)")
    }

    @Test func imagesHaveTheirOwnLane() async {
        let (limiter, clock) = make()
        await limiter.wait(for: .other)
        await limiter.wait(for: .images)
        #expect(clock.slept.isEmpty, "an image doesn't queue behind the API bucket")
        await limiter.wait(for: .images)
        #expect(approx(clock.slept, [0.2]), "but images space themselves at 5/sec: \(clock.slept)")
    }

    @Test func aBackOffHoldsEverythingScryfallAndNothingElse() async {
        let (limiter, clock) = make()
        await limiter.backOff(seconds: 60)
        #expect(await limiter.scryfallPauseRemaining == 60)
        await limiter.wait(for: .edhrec)
        #expect(clock.slept.isEmpty, "other hosts are not Scryfall's problem")
        await limiter.wait(for: .images)
        #expect(approx(clock.slept, [60]), "images wait out the pause too: \(clock.slept)")
        await limiter.wait(for: .cardsCollection)
        #expect(clock.slept.reduce(0, +) < 61, "after the pause, nothing more than the family spacing: \(clock.slept)")
        #expect(await limiter.scryfallPauseRemaining == 0)
        // A shorter back-off never cuts a longer one short.
        await limiter.backOff(seconds: 30)
        await limiter.backOff(seconds: 5)
        #expect(await limiter.scryfallPauseRemaining == 30)
    }

    /// MTGJSON is not Scryfall: its own lane, outside the shared bucket,
    /// and a Scryfall 429 doesn't hold it.
    @Test func mtgjsonHasItsOwnLaneOutsideScryfall() async {
        #expect(!RateLimitCategory.mtgjson.isScryfallAPI && !RateLimitCategory.mtgjson.isScryfall)
        let (limiter, clock) = make()
        await limiter.wait(for: .other)
        await limiter.wait(for: .mtgjson)
        #expect(clock.slept.isEmpty, "a precon file doesn't queue behind the API bucket")
        await limiter.wait(for: .cardsCollection)
        #expect(approx(clock.slept, [0.2]), "and doesn't spend it: only the API's own spacing, \(clock.slept)")
        await limiter.backOff(seconds: 60)
        let before = clock.slept.count
        await limiter.wait(for: .mtgjson)
        #expect(clock.slept.dropFirst(before).allSatisfy { $0 < 1 }, "a Scryfall pause doesn't hold MTGJSON: \(clock.slept)")
    }

    /// A cancelled caller (a tile scrolled past) leaves at once and takes
    /// no slot, so the next request isn't spaced around it.
    @Test func aCancelledWaiterTakesNoSlot() async {
        let (limiter, clock) = make()
        await limiter.wait(for: .images)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await limiter.wait(for: .images)
        }.value
        #expect(clock.slept.isEmpty, "the cancelled wait didn't sleep: \(clock.slept)")
        await limiter.wait(for: .images)
        #expect(approx(clock.slept, [0.2]), "one spacing after the first, not two: \(clock.slept)")
    }

    /// Cancelled *while sleeping* (the flick, the superseded search): the
    /// reservation goes back, so the next caller is spaced from the last
    /// request that ran, not from one that never happened.
    @Test func aWaiterCancelledWhileSleepingGivesItsSlotBack() async {
        final class CancelNextSleep: @unchecked Sendable {
            private var armed = false
            private let lock = NSLock()
            func arm() { lock.lock(); armed = true; lock.unlock() }
            func take() -> Bool { lock.lock(); defer { armed = false; lock.unlock() }; return armed }
        }
        let clock = Clock()
        let cancel = CancelNextSleep()
        // `Task.sleep` wakes at once on cancellation: the clock doesn't move.
        let limiter = RateLimiter(now: { clock.time() }, sleep: { seconds in
            if cancel.take() { withUnsafeCurrentTask { $0?.cancel() }; return }
            clock.sleep(seconds)
        })
        for category in [RateLimitCategory.images, .cardsSearch] {
            clock.slept = []
            await limiter.wait(for: category)   // first in its lane: no wait
            cancel.arm()
            await Task { await limiter.wait(for: category) }.value
            await limiter.wait(for: category)
            #expect(approx(clock.slept, [category.minInterval]),
                    "\(category): one spacing after the request that ran, not two: \(clock.slept)")
        }
    }

    @Test func retryAfterParsing() {
        #expect(RateLimiter.retryAfter("60") == 60)
        #expect(RateLimiter.retryAfter(" 7 ") == 7)
        #expect(RateLimiter.retryAfter(nil) == RateLimiter.defaultBackOff)
        #expect(RateLimiter.retryAfter("") == RateLimiter.defaultBackOff)
        #expect(RateLimiter.retryAfter("garbage") == RateLimiter.defaultBackOff)
        let soon = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let fromDate = RateLimiter.retryAfter(formatter.string(from: soon))
        #expect(fromDate > 100 && fromDate <= 120)
    }

    @Test func familiesStayUnderScryfallsLimits() {
        // Half of what Scryfall publishes: 2/sec search families, 10/sec
        // the rest, 10/min the manifest.
        #expect(RateLimitCategory.cardsSearch.minInterval >= 1.0)
        #expect(RateLimitCategory.cardsCollection.minInterval >= 1.0)
        #expect(RateLimitCategory.other.minInterval >= 0.2)
        #expect(RateLimitCategory.images.minInterval >= 0.2)
        #expect(RateLimitCategory.cardsManifest.minInterval >= 12)
        #expect(RateLimiter.scryfallAPIInterval >= 0.2)
    }
}
