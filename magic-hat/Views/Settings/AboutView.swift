//
//  AboutView.swift
//  magic-hat
//
//  About Magic Hat: the version, a way to get in touch, the privacy
//  policy, the legal disclaimer (Wizards' Fan Content Policy, and that
//  prices are estimates) and the data and fonts the app is built on. The
//  policy and disclaimer are in the app, not links: they describe this
//  build, and they read offline.
//

import SwiftUI

nonisolated enum AboutInfo {
    /// Where "Contact" writes to. Replace with the support address before
    /// shipping.
    static let contactEmail = "support@example.com"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    static var contactURL: URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = contactEmail
        comps.queryItems = [URLQueryItem(name: "subject", value: "Magic Hat \(version)")]
        return comps.url
    }
}

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.tint)
                    Text("Magic Hat").font(.title2.weight(.semibold))
                    Text("Version \(AboutInfo.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("about-version")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                if let url = AboutInfo.contactURL {
                    Link(destination: url) {
                        Label("Contact", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("about-contact")
                }
                NavigationLink {
                    LegalTextView(title: "Privacy Policy", sections: LegalText.privacy)
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("about-privacy")
                NavigationLink {
                    LegalTextView(title: "Disclaimer", sections: LegalText.disclaimer)
                } label: {
                    Label("Disclaimer", systemImage: "exclamationmark.shield")
                }
                .accessibilityIdentifier("about-disclaimer")
                NavigationLink {
                    LegalTextView(title: "Acknowledgements", sections: LegalText.acknowledgements)
                } label: {
                    Label("Acknowledgements", systemImage: "heart")
                }
                .accessibilityIdentifier("about-acknowledgements")
            }

            Section {
                Text(LegalText.shortDisclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A titled page of short sections, for the policy texts.
struct LegalTextView: View {
    let title: String
    let sections: [LegalText.Section]

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    Text(section.body)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

nonisolated enum LegalText {
    struct Section: Identifiable, Sendable {
        let title: String
        let body: String
        var id: String { title }
    }

    static let shortDisclaimer = "Magic Hat is unofficial Fan Content permitted under the Fan Content Policy. Not approved or endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. ©Wizards of the Coast LLC."

    static let privacy: [Section] = [
        Section(title: "What stays on your phone",
                body: "Your collections, lists, decks, history, saved searches and settings are stored on this device only. There is no account, no sign-in, no analytics and no advertising. Nothing you enter is sent to us."),
        Section(title: "What the app asks the internet for",
                body: "Card data, images, prices and search results come from Scryfall (scryfall.com). Deck analysis asks Commander Spellbook for combos, EDHREC for what is commonly played, and Recommander for meta picks; each request carries card names or ids, never anything about you. The card catalog and rulings are downloaded from Scryfall's bulk data. Every request identifies the app as Magic Hat, not you."),
        Section(title: "Camera",
                body: "The Scan tab uses the camera to read a card's name and set code on the device. Images are processed on the phone and never stored or uploaded; only the recognised text is used to look the card up on Scryfall."),
        Section(title: "Backups",
                body: "A backup is a file you create and keep: exported through the share sheet, or written to an iCloud Drive folder you choose for automatic backups. Those files are yours and are handled by iCloud Drive under Apple's terms; the app never reads a folder you haven't picked."),
        Section(title: "Links to stores",
                body: "Buy links open TCGplayer or Card Kingdom in your browser with the cards to buy. What happens there is under that store's privacy policy."),
        Section(title: "Deleting your data",
                body: "Delete a collection, list or deck in the app, or delete the app to remove everything it stored. Backups you made are not touched."),
    ]

    static let disclaimer: [Section] = [
        Section(title: "Fan Content",
                body: shortDisclaimer + " Magic: The Gathering, its card names, mana symbols and card images are trademarks and copyright of Wizards of the Coast LLC, a subsidiary of Hasbro, Inc."),
        Section(title: "Card data",
                body: "Card data and images are provided by Scryfall. Magic Hat is not produced by or endorsed by Scryfall, EDHREC, Commander Spellbook, Recommander, MTGJSON, TCGplayer or Card Kingdom."),
        Section(title: "Prices",
                body: "Prices are Scryfall's daily market figures (TCGplayer in dollars, Cardmarket in euros). They are estimates for information only, may be out of date, and are not an offer to buy or sell."),
        Section(title: "Recommendations",
                body: "Deck scores, brackets, swaps and recommendations are rules of thumb read from card text and public data. They are suggestions, not rulings; your playgroup decides what is fair."),
        Section(title: "Scanning",
                body: "Card recognition can be wrong. Check the printing and finish before adding a scanned card."),
    ]

    static let acknowledgements: [Section] = [
        Section(title: "Scryfall", body: "Card data, images, prices, rulings and search. scryfall.com"),
        Section(title: "Keyrune", body: "Set symbol font by Andrew Gioia, SIL Open Font License 1.1."),
        Section(title: "Mana", body: "Mana and card symbol font by Andrew Gioia, SIL Open Font License 1.1."),
        Section(title: "Commander Spellbook", body: "Combo data. commanderspellbook.com"),
        Section(title: "EDHREC", body: "Commander synergy and popularity data. edhrec.com"),
        Section(title: "Recommander", body: "Meta recommendations for Commander decks."),
        Section(title: "MTGJSON", body: "Preconstructed deck and set data. mtgjson.com"),
    ]
}

#Preview {
    NavigationStack { AboutView() }
}
