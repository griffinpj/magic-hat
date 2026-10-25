//
//  GridDiagnostics.swift
//  magic-hat
//
//  Kill-switches for what a grid tile draws — the glow, the foil sheen,
//  the images, the caption — so a scroll on a ProMotion phone can say
//  which one costs the frames. Instruments can't record on the iOS 27
//  phone and the simulator reports no frame pacing, so the phone itself
//  is the instrument: switch one thing off in Settings › Grid Diagnostics
//  (debug builds only), scroll, feel. Everything is on by default and the
//  section does not exist in a release build.
//
//  Read in every tile's body, so the values are held behind a lock rather
//  than read from UserDefaults each time.
//

import Foundation
import os

nonisolated enum GridDiagnostics {
    static let glowKey = "debug.grid.glow"
    static let sheenKey = "debug.grid.sheen"
    static let imagesKey = "debug.grid.images"
    static let captionKey = "debug.grid.caption"
    static let frameRateKey = "debug.grid.frameRate"
    static let allKeys = [glowKey, sheenKey, imagesKey, captionKey, frameRateKey]

    struct Flags: Sendable, Equatable {
        var glow = true
        var sheen = true
        var images = true
        var caption = true
        static let everything = Flags()
    }

    private static let cache = OSAllocatedUnfairLock<Flags?>(initialState: nil)

    static var current: Flags {
        #if DEBUG
        return cache.withLock { state in
            if let state { return state }
            let d = UserDefaults.standard
            // `UITEST_GRID_OFF=glow,sheen` turns draws off for one launch,
            // so the hitch metric can run with each one out in turn.
            let off = Set((ProcessInfo.processInfo.environment["UITEST_GRID_OFF"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            func on(_ key: String) -> Bool {
                if off.contains(key.replacingOccurrences(of: "debug.grid.", with: "")) { return false }
                return d.object(forKey: key) == nil ? true : d.bool(forKey: key)
            }
            let flags = Flags(glow: on(glowKey), sheen: on(sheenKey), images: on(imagesKey), caption: on(captionKey))
            state = flags
            return flags
        }
        #else
        return .everything
        #endif
    }

    /// After a toggle in Settings (or the seed clearing the keys).
    static func reload() {
        cache.withLock { $0 = nil }
    }
}
