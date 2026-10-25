//
//  ImagePrefetchController.swift
//  magic-hat
//
//  Downloads the picture of every owned card to the disk cache, so a
//  scroll into a part of the collection never seen meets images already
//  on the phone. Without it the grid fetched only what came into view
//  and thirty tiles ahead, through the images lane at 5/sec: a screen of
//  fifteen cards in a region never scrolled took three seconds to fill,
//  grey card by grey card, however smooth the frames were — the one
//  thing the apps that feel instant do differently is that they have the
//  bytes.
//
//  Runs after the hydration sync (which is what gives the rows their
//  image URLs), at background priority, bytes only — nothing is decoded,
//  so it costs no memory and the grid still decodes at its own size. It
//  stands aside while the grid is loading (`ImageLoader.prefetch` waits
//  out a recent interactive load), refuses a metered path unless images
//  are allowed on cellular, and reports to Data Activity as Card Images.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class ImagePrefetchController {
    static let shared = ImagePrefetchController()

    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    /// Starts a pass if none is running. Idempotent and cheap when every
    /// image is already on disk: the check is a stat per card, off the
    /// main actor, and Data Activity records "up to date".
    func runIfNeeded(container: ModelContainer) {
        guard task == nil else { return }
        guard AppSettings.imagesOnCellular || !NetworkMonitor.isMeteredNow else {
            DataActivity.shared.skip(.cardImages, note: "Waiting for Wi-Fi")
            return
        }
        isRunning = true
        task = Task(priority: .background) { [weak self] in
            defer {
                self?.task = nil
                self?.isRunning = false
            }
            let store = CollectionStore.shared(for: container)
            guard let urls = try? await store.ownedImageURLs(stamp: .current) else { return }
            let missing = await ImageLoader.shared.missingFromDisk(urls)
            guard !missing.isEmpty else {
                DataActivity.shared.skip(.cardImages, note: "Up to date · \(urls.count.formatted()) on this phone")
                return
            }
            DataActivity.shared.begin(.cardImages, total: missing.count)
            let result = await ImageLoader.shared.prefetch(missing) { done in
                await MainActor.run { DataActivity.shared.progress(.cardImages, done: done) }
            }
            if Task.isCancelled { return }
            let short = missing.count - result.fetched - result.failed
            var note = "\(result.fetched.formatted()) images"
            if result.failed > 0 { note += " · \(result.failed.formatted()) failed" }
            if short > 0 { note += " · \(short.formatted()) left for next time" }
            DataActivity.shared.end(.cardImages, count: result.fetched, note: note, failed: result.fetched == 0 && result.failed > 0)
        }
    }

    func cancel() {
        task?.cancel()
    }
}
