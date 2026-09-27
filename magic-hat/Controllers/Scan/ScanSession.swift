//
//  ScanSession.swift
//  magic-hat
//
//  The scanner's state between the camera and the screen. Frames arrive a
//  few times a second; a reading is only acted on once two of the last
//  three frames agree on it, so a card half out of the guide, a glare or a
//  blur never becomes a lookup. A sure match goes straight into the tray
//  (with a haptic); an unsure one stops and asks. The card just added is
//  then ignored until it leaves the guide, so holding a card still adds it
//  once — scanning it again after it has gone counts another copy.
//
//  The tray is the ManaBox shape: each scanned card with its printing,
//  finish and count, all editable, added to a collection or list in one
//  step as one History action.
//

import Foundation
import Observation
import SwiftData

nonisolated struct ScanTrayItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    var card: CardItem
    var printing: PrintingSelection
    var finish: CardFinish
    var quantity: Int
    /// The printing was read off the card rather than guessed.
    var exactPrinting: Bool
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
    }

    private(set) var phase: Phase = .looking
    private(set) var tray: [ScanTrayItem] = []
    /// Bumped on every card into the tray, for the haptic.
    private(set) var addedCount = 0
    var isPaused: Bool { if case .confirm = phase { return true } else { return false } }

    private var knownSets: Set<String> = []
    private var recent: [String] = []
    private var matchingKey: String?
    /// The card last added, ignored until the guide has been empty (or
    /// shown something else) for a moment.
    private var cooldownName: String?
    private var emptyFrames = 0
    private var matchTask: Task<Void, Never>?

    var trayCopies: Int { tray.reduce(0) { $0 + $1.quantity } }

    func loadSets() async {
        guard knownSets.isEmpty, let sets = try? await ScryfallCatalogCache.shared.sets() else { return }
        knownSets = Set(sets.map { $0.code.lowercased() })
    }

    /// One analysed frame.
    func ingest(_ lines: [RecognizedLine]) {
        guard !isPaused else { return }
        let reading = CardTextReader.read(lines, knownSets: knownSets)
        guard let name = reading.name else {
            emptyFrames += 1
            if emptyFrames >= 4 {
                cooldownName = nil
                recent.removeAll()
                if case .added = phase {} else if matchingKey == nil { phase = .looking }
            }
            return
        }
        emptyFrames = 0
        if let cooldownName, CardTextReader.similarity(cooldownName, name) >= 0.7 { return }
        cooldownName = nil

        recent.append(reading.key)
        if recent.count > 3 { recent.removeFirst() }
        let agreeing = recent.filter { $0 == reading.key }.count
        guard agreeing >= 2 else {
            if matchingKey == nil { phase = .reading(name) }
            return
        }
        guard matchingKey != reading.key else { return }
        matchingKey = reading.key
        phase = .matching(name)
        matchTask?.cancel()
        matchTask = Task {
            let match = await ScanMatcher.match(reading)
            guard !Task.isCancelled else { return }
            matchingKey = nil
            recent.removeAll()
            guard let match else { phase = .looking; return }
            switch match.confidence {
            case .sure: accept(match.card, exactPrinting: match.exactPrinting)
            case .unsure: phase = .confirm(match)
            }
        }
    }

    /// The user's answer to "Is this …?": the card, or another name.
    func confirm(_ card: ScryfallCard, exactPrinting: Bool) {
        accept(card, exactPrinting: exactPrinting)
    }

    func confirm(name: String) {
        phase = .matching(name)
        Task {
            if let card = try? await ScryfallClient.shared.named(fuzzy: name) {
                accept(card, exactPrinting: false)
            } else {
                phase = .looking
            }
        }
    }

    func dismissPrompt() {
        if case .confirm(let match) = phase { cooldownName = match.card.name }
        phase = .looking
    }

    /// A still photo: read once, no voting — it can't be blurry twice.
    func scan(photoLines lines: [RecognizedLine]) async {
        let reading = CardTextReader.read(lines, knownSets: knownSets)
        guard let name = reading.name else { phase = .looking; return }
        phase = .matching(name)
        guard let match = await ScanMatcher.match(reading) else { phase = .looking; return }
        switch match.confidence {
        case .sure: accept(match.card, exactPrinting: match.exactPrinting)
        case .unsure: phase = .confirm(match)
        }
    }

    private func accept(_ card: ScryfallCard, exactPrinting: Bool) {
        let item = CardItem(scryfallCard: card, owned: false)
        let printing = PrintingSelection(card: card)
        // The same printing again: another copy.
        if let i = tray.firstIndex(where: { $0.printing.scryfallID == printing.scryfallID && $0.finish == .normal }) {
            tray[i].quantity += 1
            let moved = tray.remove(at: i)
            tray.insert(moved, at: 0)
        } else {
            tray.insert(ScanTrayItem(card: item, printing: printing, finish: .normal, quantity: 1, exactPrinting: exactPrinting), at: 0)
        }
        cooldownName = card.name
        addedCount += 1
        phase = .added(item)
    }

    // MARK: Tray

    func update(_ item: ScanTrayItem) {
        guard let i = tray.firstIndex(where: { $0.id == item.id }) else { return }
        if item.quantity <= 0 { tray.remove(at: i) } else { tray[i] = item }
    }

    func remove(_ id: UUID) { tray.removeAll { $0.id == id } }
    func clear() { tray.removeAll(); phase = .looking }

    /// Everything in the tray into `collection`, as one action.
    func addAll(to collection: String, context: ModelContext) throws {
        let requests = tray.map { item in
            CollectionEditController.AddRequest(
                printing: item.printing, collectionName: collection, quantity: item.quantity, finish: item.finish,
                condition: CardCondition.nearMint.rawValue, language: AppSettings.cardLanguage,
                purchasePrice: item.printing.marketPrice(for: item.finish)
            )
        }
        try CollectionEditController.addMany(requests, context: context)
        tray.removeAll()
        phase = .looking
    }
}
