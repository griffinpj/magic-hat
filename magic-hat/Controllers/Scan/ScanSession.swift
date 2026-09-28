//
//  ScanSession.swift
//  magic-hat
//
//  The scanner's state between the camera and the screen. Frames arrive a
//  few times a second; a reading is only acted on once two of the last
//  three frames agree on it, so a card half out of the guide, a glare or a
//  blur never becomes a lookup. A sure match goes into the tray (a haptic,
//  and a sound unless it's off); an unsure one stops and asks.
//
//  A card is never counted twice by accident. The card just scanned is
//  ignored while it stays in the guide, and scanning the same printing
//  again right after it — the same card held a second time, or a glare
//  that made the reader lose it for a moment — adds nothing: another copy
//  is the overlay's +1, as in ManaBox. A *different printing* of the same
//  card (another set or number read off it) is a new card.
//
//  The card at the head of the tray is the one the overlay edits in place
//  — printing, finish, language, count — without leaving the camera; the
//  tray itself is the review before everything goes into a collection or
//  list as one History action.
//

import Foundation
import Observation
import SwiftData

nonisolated struct ScanTrayItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    var card: CardItem
    var printing: PrintingSelection
    var finish: CardFinish
    var language: String
    var quantity: Int
    /// The printing was read off the card rather than chosen for it.
    var exactPrinting: Bool
    /// Finishes the printing exists in (Scryfall's "nonfoil"/"foil"/"etched").
    var finishes: [CardFinish] = CardFinish.allCases

    var price: Double? { printing.marketPrice(for: finish) }
}

nonisolated extension CardFinish {
    /// Scryfall's `finishes` names.
    static func fromScryfall(_ names: [String]?) -> [CardFinish] {
        guard let names, !names.isEmpty else { return CardFinish.allCases }
        let out = names.compactMap { name -> CardFinish? in
            switch name {
            case "nonfoil": return .normal
            case "foil": return .foil
            case "etched": return .etched
            default: return nil
            }
        }
        return out.isEmpty ? CardFinish.allCases : out
    }
}

@MainActor
@Observable
final class ScanSession {
    enum Phase: Equatable {
        /// Nothing in the guide worth reading.
        case looking
        /// Text seen; waiting for frames to agree.
        case reading(String)
        /// Asking Scryfall.
        case matching(String)
        /// Not sure: the user decides.
        case confirm(ScanMatch)
        /// Added to the tray.
        case added(CardItem)
        /// The card just scanned, seen again: nothing added.
        case again(CardItem)
        /// Found, but outside the sets scanning is locked to.
        case skipped(String)
    }

    private(set) var phase: Phase = .looking
    private(set) var tray: [ScanTrayItem] = []
    /// Bumped on every card into the tray (haptic, sound).
    private(set) var addedCount = 0
    /// The overlay is being edited: no new scans until it closes.
    var isEditing = false
    var isPaused: Bool {
        if isEditing { return true }
        if case .confirm = phase { return true }
        return false
    }

    let settings: ScanSettings
    private var knownSets: Set<String> = []
    private var recent: [String] = []
    private var matchingKey: String?
    /// The card last taken into the tray (its name, and its printing when
    /// that was read), ignored until a different card is read.
    private var lastTaken: (name: String, printingKey: String?)?
    private var matchTask: Task<Void, Never>?
    /// A reading that found nothing, and when: not asked again for a few
    /// seconds, so a card Scryfall can't place isn't looked up four times
    /// a second while it sits in the guide.
    private var failed: (key: String, at: Date)?
    private var emptySince: Date?

    init(settings: ScanSettings) {
        self.settings = settings
    }

    var trayCopies: Int { tray.reduce(0) { $0 + $1.quantity } }
    /// The card the overlay edits: the one scanned last.
    var current: ScanTrayItem? { tray.first }

    /// The tray's value, low values left out when the setting says so.
    var totalValue: Double {
        tray.reduce(0) { sum, item in
            guard let price = item.price, !(settings.ignoreLowValues && price < 1) else { return sum }
            return sum + price * Double(item.quantity)
        }
    }

    func loadSets() async {
        guard knownSets.isEmpty, let sets = try? await ScryfallCatalogCache.shared.sets() else { return }
        knownSets = Set(sets.map { $0.code.lowercased() })
    }

    // MARK: Frames

    /// Whether a settled reading is the card just taken, seen again: the
    /// same name, and no printing read that says it is another one.
    nonisolated static func isSameAsLast(_ reading: ScanReading, last: (name: String, printingKey: String?)?) -> Bool {
        guard let last, let name = reading.name, CardTextReader.similarity(last.name, name) >= 0.85 else { return false }
        if let set = reading.setCode, let number = reading.collectorNumber, let lastKey = last.printingKey {
            return "\(set)|\(number)" == lastKey
        }
        return true
    }

    /// One analysed frame.
    func ingest(_ lines: [RecognizedLine]) {
        guard !isPaused else { return }
        let reading = CardTextReader.read(lines, knownSets: knownSets)
        guard reading.name != nil else {
            // A clear guide for over a second: the next card may be anything.
            if emptySince == nil { emptySince = Date() }
            if let since = emptySince, Date().timeIntervalSince(since) > 1.2 {
                recent.removeAll()
                if matchingKey == nil { phase = .looking }
            }
            return
        }
        emptySince = nil
        // The card just taken, still in the guide (or back in it): nothing
        // to do — another copy is the +1.
        if Self.isSameAsLast(reading, last: lastTaken) {
            if case .added = phase {} else if case .again = phase {} else if let current {
                phase = .again(current.card)
            }
            return
        }

        recent.append(reading.key)
        if recent.count > 3 { recent.removeFirst() }
        let agreeing = recent.filter { $0 == reading.key }.count
        guard agreeing >= 2 else {
            if matchingKey == nil, let name = reading.name { phase = .reading(name) }
            return
        }
        guard matchingKey != reading.key else { return }
        if let failed, failed.key == reading.key, Date().timeIntervalSince(failed.at) < 4 { return }
        matchingKey = reading.key
        phase = .matching(reading.name ?? "")
        matchTask?.cancel()
        let options = settings.matchOptions
        matchTask = Task {
            let outcome = await ScanMatcher.match(reading, options: options)
            guard !Task.isCancelled else { return }
            matchingKey = nil
            recent.removeAll()
            handle(outcome, reading: reading)
        }
    }

    private func handle(_ outcome: ScanOutcome, reading: ScanReading) {
        switch outcome {
        case .nothing:
            failed = (reading.key, Date())
            phase = .looking
        case .outsideLockedSets(let name):
            failed = (reading.key, Date())
            phase = .skipped(name)
        case .match(let match):
            switch match.confidence {
            case .sure: accept(match.card, exactPrinting: match.exactPrinting, reading: reading)
            case .unsure: phase = .confirm(match)
            }
        }
    }

    /// The user's answer to "Is this …?": the card, or another name.
    func confirm(_ card: ScryfallCard, exactPrinting: Bool) {
        accept(card, exactPrinting: exactPrinting, reading: nil)
    }

    func confirm(name: String) {
        phase = .matching(name)
        Task {
            if let card = try? await ScryfallClient.shared.named(fuzzy: name) {
                accept(card, exactPrinting: false, reading: nil)
            } else {
                phase = .looking
            }
        }
    }

    func dismissPrompt() {
        if case .confirm(let match) = phase { lastTaken = (match.card.name, nil) }
        phase = .looking
    }

    /// A still photo: read once, no voting — it can't be blurry twice.
    func scan(photoLines lines: [RecognizedLine]) async {
        let reading = CardTextReader.read(lines, knownSets: knownSets)
        guard let name = reading.name else { phase = .looking; return }
        phase = .matching(name)
        handle(await ScanMatcher.match(reading, options: settings.matchOptions), reading: reading)
    }

    /// Into the tray, at the head, so the overlay edits it. The same
    /// printing as the card at the head is never a new row: that is
    /// scanning one card twice.
    func accept(_ card: ScryfallCard, exactPrinting: Bool, reading: ScanReading?) {
        let item = CardItem(scryfallCard: card, owned: false)
        let printing = PrintingSelection(card: card)
        let finishes = CardFinish.fromScryfall(card.finishes)
        var finish: CardFinish = .normal
        if reading?.foil == true, finishes.contains(.foil) { finish = .foil }
        else if settings.preferFoil, finishes.contains(.foil) { finish = .foil }
        else if !finishes.contains(.normal), let only = finishes.first { finish = only }
        let language = reading?.language ?? AppSettings.cardLanguage
        lastTaken = (card.name, "\(card.set.lowercased())|\(card.collectorNumber)")

        if let head = tray.first, head.printing.scryfallID == printing.scryfallID {
            phase = .again(head.card)
            return
        }
        tray.insert(ScanTrayItem(card: item, printing: printing, finish: finish, language: language, quantity: 1,
                                 exactPrinting: exactPrinting, finishes: finishes), at: 0)
        addedCount += 1
        phase = .added(item)
        if !exactPrinting, !settings.quickMode { wantsPrintingPicker = true }
    }

    /// Set when a card came in whose printing wasn't read and quick mode
    /// is off: the overlay opens its printing picker. The view clears it.
    var wantsPrintingPicker = false

    // MARK: The current card

    func incrementCurrent() {
        guard !tray.isEmpty else { return }
        tray[0].quantity += 1
        addedCount += 1
    }

    /// One fewer; at zero the card leaves the tray.
    func decrementCurrent() {
        guard !tray.isEmpty else { return }
        if tray[0].quantity > 1 {
            tray[0].quantity -= 1
        } else {
            tray.removeFirst()
            lastTaken = nil
            phase = .looking
        }
    }

    func setCurrentFinish(_ finish: CardFinish) {
        guard !tray.isEmpty else { return }
        tray[0].finish = finish
    }

    func setCurrentLanguage(_ language: String) {
        guard !tray.isEmpty else { return }
        tray[0].language = language
    }

    /// Another printing of the current card, picked in the overlay.
    func setCurrentPrinting(_ card: ScryfallCard) {
        guard !tray.isEmpty else { return }
        tray[0].card = CardItem(scryfallCard: card, owned: false)
        tray[0].printing = PrintingSelection(card: card)
        tray[0].finishes = CardFinish.fromScryfall(card.finishes)
        if !tray[0].finishes.contains(tray[0].finish), let first = tray[0].finishes.first { tray[0].finish = first }
        tray[0].exactPrinting = true
        lastTaken = (card.name, "\(card.set.lowercased())|\(card.collectorNumber)")
    }

    // MARK: Tray

    func update(_ item: ScanTrayItem) {
        guard let i = tray.firstIndex(where: { $0.id == item.id }) else { return }
        if item.quantity <= 0 { tray.remove(at: i) } else { tray[i] = item }
    }

    func remove(_ id: UUID) {
        tray.removeAll { $0.id == id }
        if tray.isEmpty { lastTaken = nil }
    }

    func clear() {
        tray.removeAll()
        lastTaken = nil
        phase = .looking
    }

    /// Everything in the tray into `collection`, as one action.
    func addAll(to collection: String, context: ModelContext) async throws {
        let requests = tray.map { item in
            CollectionEditController.AddRequest(
                printing: item.printing, collectionName: collection, quantity: item.quantity, finish: item.finish,
                condition: CardCondition.nearMint.rawValue, language: item.language,
                purchasePrice: item.price
            )
        }
        try await CollectionEditController.addMany(requests, context: context)
        clear()
    }
}
