//
//  PlaytestOptions.swift
//  magic-hat
//
//  What can be done with one card at the table, from where it is, as data:
//  the playtest's card inspector draws these and hands the chosen command
//  back to `apply`. Kept with the state rather than the screen so the
//  offer is tested with the rules — an instant in hand offers a cast that
//  says it resolves into the graveyard, never "onto the battlefield"; a
//  card in the graveyard offers flashback; the opening hand offers
//  nothing to play.
//

import Foundation

/// One thing the table can do to a card.
nonisolated enum PlaytestCommand: Hashable, Sendable {
    /// Play or cast it; `force` is the player's say-so past an issue (an
    /// extra land, mana the sources can't make).
    case play(PlaytestPlay, force: Bool)
    case toggleTap
    case transform
    case tokenCopy
    case move(PlaytestZone, LibraryEnd)
    /// A mulligan's card to the bottom.
    case bottom
    case discard
}

/// A command as the inspector offers it.
nonisolated struct PlaytestOption: Identifiable, Hashable, Sendable {
    let command: PlaytestCommand
    let title: String
    let systemImage: String
    /// What happens, or what needs the player's say-so.
    var caption: String? = nil
    var isPrimary = false
    var isDestructive = false
    /// Tapping or turning a card over leaves the inspector up.
    var keepsOpen = false

    var id: String { title }
}

nonisolated extension PlaytestState {
    /// Where the card is, in words: "In your hand", "On the battlefield ·
    /// tapped · summoning sick", "In the command zone · tax {2}".
    func whereabouts(of id: UUID) -> String {
        guard let zone = zone(of: id), let card = card(id) else { return "" }
        switch zone {
        case .hand: return "In your hand"
        case .library: return "In your library"
        case .graveyard: return "In your graveyard"
        case .exile: return card.onAdventure ? "In exile · on an adventure" : "In exile"
        case .command:
            let tax = 2 * (commanderCasts[id] ?? 0)
            return tax > 0 ? "In the command zone · tax {\(tax)}" : "In the command zone"
        case .battlefield:
            var parts = [card.isToken ? "A token on the battlefield" : "On the battlefield"]
            if card.isTapped { parts.append("tapped") }
            if card.isSummoningSick(on: turn) { parts.append("summoning sick") }
            return parts.joined(separator: " · ")
        }
    }

    /// Everything the card can do from where it is, the main thing first.
    func options(for id: UUID, autoPay: Bool = true) -> [PlaytestOption] {
        guard let zone = zone(of: id), let card = card(id) else { return [] }
        var options: [PlaytestOption] = []
        switch zone {
        case .hand:
            switch phase {
            case .opening:
                return []
            case .bottoming:
                return [PlaytestOption(command: .bottom, title: "Put on the Bottom", systemImage: "arrow.down.to.line",
                                       caption: "One of the mulligan’s cards", isPrimary: true)]
            case .cleanup:
                return [PlaytestOption(command: .discard, title: "Discard", systemImage: "archivebox",
                                       caption: "Down to \(rules.handSize) at the end of the turn", isPrimary: true)]
            case .main:
                options += plays(id, autoPay: autoPay)
                options.append(PlaytestOption(command: .discard, title: "Discard", systemImage: "archivebox"))
                options.append(PlaytestOption(command: .move(.exile, .top), title: "Exile", systemImage: "xmark.bin"))
                options += libraryOptions
            }
        case .command:
            options += plays(id, autoPay: autoPay)
            if phase == .main, card.info.front.isPermanent {
                options.append(PlaytestOption(command: .move(.battlefield, .top), title: "Put onto the Battlefield",
                                              systemImage: "arrow.up.right", caption: "Without casting it: no tax"))
            }
            options.append(PlaytestOption(command: .move(.hand, .top), title: "To Hand", systemImage: "hand.raised"))
        case .battlefield:
            options.append(PlaytestOption(command: .toggleTap, title: card.isTapped ? "Untap" : "Tap", systemImage: "arrow.clockwise",
                                          isPrimary: true, keepsOpen: true))
            if card.info.transforms {
                options.append(PlaytestOption(command: .transform, title: "Transform", systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                                              keepsOpen: true))
            }
            options.append(PlaytestOption(command: .tokenCopy, title: "Token Copy", systemImage: "plus.square.on.square"))
            if card.isCommander {
                options.append(PlaytestOption(command: .move(.command, .top), title: "To Command Zone", systemImage: "crown"))
            }
            let gone = card.isToken ? "A token ceases to exist when it leaves" : nil
            options.append(PlaytestOption(command: .move(.hand, .top), title: "Return to Hand", systemImage: "hand.raised", caption: gone))
            options.append(PlaytestOption(command: .move(.graveyard, .top), title: "Destroy / Sacrifice", systemImage: "archivebox",
                                          caption: gone, isDestructive: true))
            options.append(PlaytestOption(command: .move(.exile, .top), title: "Exile", systemImage: "xmark.bin", caption: gone))
            options += libraryOptions
        case .graveyard, .exile:
            options += plays(id, autoPay: autoPay)
            options.append(PlaytestOption(command: .move(.hand, .top), title: "Return to Hand", systemImage: "hand.raised"))
            if card.info.front.isPermanent {
                options.append(PlaytestOption(command: .move(.battlefield, .top), title: "Return to the Battlefield", systemImage: "arrow.up.right"))
            }
            if zone == .graveyard {
                options.append(PlaytestOption(command: .move(.exile, .top), title: "Exile", systemImage: "xmark.bin"))
            } else {
                options.append(PlaytestOption(command: .move(.graveyard, .top), title: "To Graveyard", systemImage: "archivebox"))
            }
            options += libraryOptions
            if card.isCommander {
                options.append(PlaytestOption(command: .move(.command, .top), title: "To Command Zone", systemImage: "crown"))
            }
        case .library:
            return []
        }
        return options
    }

    private var libraryOptions: [PlaytestOption] {
        [PlaytestOption(command: .move(.library, .top), title: "Top of Library", systemImage: "arrow.up.to.line"),
         PlaytestOption(command: .move(.library, .bottom), title: "Bottom of Library", systemImage: "arrow.down.to.line")]
    }

    /// Each way to play the card, saying where it will go and what it
    /// costs — or what needs the player's say-so, in which case choosing
    /// it is that say-so.
    private func plays(_ id: UUID, autoPay: Bool) -> [PlaytestOption] {
        guard let card = card(id), let zone = zone(of: id) else { return [] }
        var out: [PlaytestOption] = []
        for play in playOptions(id) {
            guard let face = face(id, for: play) else { continue }
            let problem = issue(playing: id, as: play, autoPay: autoPay)
            if problem == .notMainPhase || problem == .notAPermanent { continue }
            let layout = card.info.layout

            let title: String
            if play == .free {
                title = "Put onto the Battlefield"
            } else if face.isLand {
                title = "Play \(face.name)"
            } else if play == .back && layout == .adventure {
                title = "Cast \(face.name) (Adventure)"
            } else if play == .back && layout == .omen {
                title = "Cast \(face.name) (Omen)"
            } else if play == .back && layout == .transform {
                title = "Cast \(face.name) (Disturb)"
            } else if zone == .graveyard && !face.isPermanent {
                title = "Flashback \(face.name)"
            } else {
                title = "Cast \(face.name)"
            }

            var parts: [String] = []
            let cost = cost(of: id, as: play)
            if let cost {
                if !cost.isKnown, !face.isLand {
                    parts.append("Cost unknown — tap for it yourself")
                } else if !cost.isFree {
                    parts.append("Costs \(ManaText.plain(cost.text))")
                }
            }
            if play == .free {
                parts.append("Without casting it")
            } else if face.isLand {
                parts.append("Your land for the turn")
            } else if face.isPermanent {
                parts.append("Resolves onto the battlefield")
            } else if play == .back && layout == .adventure && zone == .hand {
                parts.append("Then goes on an adventure in exile")
            } else if play == .back && layout == .omen {
                parts.append("Then shuffled into your library")
            } else if zone == .graveyard {
                parts.append("Exiled after it resolves")
            } else if zone == .command && card.isCommander {
                parts.append("Returns to the command zone")
            } else {
                parts.append("Resolves into the graveyard")
            }
            var force = false
            switch problem {
            case .landAlreadyPlayed:
                parts = ["You’ve played a land this turn — play another only if an effect lets you"]
                force = true
            case .cannotPay(let needed, let available):
                parts = ["Not enough mana: costs \(ManaText.plain(needed)), your untapped sources make \(available). Tap for it yourself."]
                force = true
            default:
                if autoPay, let cost, !cost.isFree, let payment = PlaytestPayer.pay(cost, from: paySources()), !payment.tapped.isEmpty {
                    parts.append("taps \(payment.tapped.count)")
                }
            }
            let icon = play == .free ? "arrow.up.right" : face.isLand ? "mountain.2" : "wand.and.stars"
            out.append(PlaytestOption(command: .play(play, force: force), title: title, systemImage: icon,
                                      caption: parts.joined(separator: " · "), isPrimary: out.isEmpty))
        }
        return out
    }

    /// Carries out an option's command.
    @discardableResult
    mutating func apply<G: RandomNumberGenerator>(_ command: PlaytestCommand, to id: UUID, autoPay: Bool = true,
                                                  using rng: inout G) -> Bool {
        switch command {
        case .play(let play, let force):
            return self.play(id, as: play, autoPay: autoPay, force: force, using: &rng) != nil
        case .toggleTap:
            toggleTap(id)
        case .transform:
            transform(id)
        case .tokenCopy:
            createTokenCopy(of: id)
        case .move(let zone, let end):
            return move(id, to: zone, libraryEnd: end)
        case .bottom:
            bottom(id)
        case .discard:
            discard(id)
        }
        return true
    }

    /// The counters a card on the battlefield can be given.
    func counterKinds(for id: UUID) -> [PlaytestCounter] {
        guard let card = battlefield.first(where: { $0.id == id }) else { return [] }
        var kinds: [PlaytestCounter] = []
        if card.face.isCreature { kinds += [.plusOne, .minusOne] }
        if card.face.isPlaneswalker { kinds.append(.loyalty) }
        kinds.append(.charge)
        return kinds
    }
}
