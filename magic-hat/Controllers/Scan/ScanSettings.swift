//
//  ScanSettings.swift
//  magic-hat
//
//  The scanner's own preferences, set from the gear on the Scan tab: which
//  camera, how sure a printing must be before it is taken, sets to limit
//  scanning to, promos, foil, sounds, and the running total. UserDefaults
//  keys, read through one observable so the scanner and its settings sheet
//  see the same values.
//

import Foundation
import Observation

@MainActor
@Observable
final class ScanSettings {
    static let shared = ScanSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let camera = "scan.camera"
        static let quickMode = "scan.quickMode"
        static let lockedSets = "scan.lockedSets"
        static let ignorePromos = "scan.ignorePromos"
        static let preferFoil = "scan.preferFoil"
        static let playSounds = "scan.playSounds"
        static let showTotal = "scan.showTotal"
        static let ignoreLowValues = "scan.ignoreLowValues"
    }

    /// The camera's unique id; nil is the default (see CardCamera).
    var cameraID: String? { didSet { defaults.set(cameraID, forKey: Key.camera) } }
    /// Take the first printing that matches the name when the card's own
    /// set and number couldn't be read. Off: the printing picker opens on
    /// the scanned card so the right one can be chosen.
    var quickMode: Bool { didSet { defaults.set(quickMode, forKey: Key.quickMode) } }
    /// Set codes (lowercase) scanning is limited to; empty is every set.
    var lockedSets: Set<String> { didSet { defaults.set(Array(lockedSets).sorted(), forKey: Key.lockedSets) } }
    var ignorePromos: Bool { didSet { defaults.set(ignorePromos, forKey: Key.ignorePromos) } }
    /// A card that has a foil printing starts as foil.
    var preferFoil: Bool { didSet { defaults.set(preferFoil, forKey: Key.preferFoil) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    var showTotal: Bool { didSet { defaults.set(showTotal, forKey: Key.showTotal) } }
    /// Leave cards under 1 (dollar or euro) out of the total.
    var ignoreLowValues: Bool { didSet { defaults.set(ignoreLowValues, forKey: Key.ignoreLowValues) } }

    private init() {
        let d = UserDefaults.standard
        cameraID = d.string(forKey: Key.camera)
        quickMode = d.object(forKey: Key.quickMode) as? Bool ?? true
        lockedSets = Set(d.stringArray(forKey: Key.lockedSets) ?? [])
        ignorePromos = d.bool(forKey: Key.ignorePromos)
        preferFoil = d.bool(forKey: Key.preferFoil)
        playSounds = d.object(forKey: Key.playSounds) as? Bool ?? true
        showTotal = d.object(forKey: Key.showTotal) as? Bool ?? true
        ignoreLowValues = d.bool(forKey: Key.ignoreLowValues)
    }

    /// What the matcher needs, as a value it can take off the main actor.
    var matchOptions: ScanMatchOptions {
        ScanMatchOptions(lockedSets: lockedSets, ignorePromos: ignorePromos)
    }
}

nonisolated struct ScanMatchOptions: Sendable, Equatable {
    var lockedSets: Set<String> = []
    var ignorePromos = false
}
