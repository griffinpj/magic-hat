//
//  CardTextReader.swift
//  magic-hat
//
//  What a frame of text says about the card in the guide. Vision hands back
//  lines with boxes; this reads them the way a player does:
//
//  - the name is the title line: the top band of the card, left side,
//    letters (mana symbols read as stray characters and are trimmed);
//  - the printing is the bottom-left info block every card since 2015
//    carries — "0123/0280 R" (or "0123 R") over "DSK • EN": a collector
//    number and a set code that must be a real set, so a stray word never
//    passes for one; the language after it; and between them a dot on a
//    nonfoil, a star (★) on a foil — the one printed tell of a foil.
//
//  Pure and nonisolated, over plain line values, so it is tested without a
//  camera. Coordinates are Vision's: normalised to the guide, origin at
//  the bottom left.
//

import Foundation
import CoreGraphics

nonisolated struct RecognizedLine: Hashable, Sendable {
    let text: String
    let confidence: Float
    /// Normalised to the card guide, origin bottom-left (Vision's).
    let box: CGRect
}

nonisolated struct ScanReading: Hashable, Sendable {
    var name: String?
    var setCode: String?
    var collectorNumber: String?
    /// The title line's own OCR confidence (0–1).
    var nameConfidence: Float = 0
    /// Scryfall's code for the language printed in the info block.
    var language: String?
    /// The info block's star: true foil, false the nonfoil dot, nil unread.
    var foil: Bool?

    var isEmpty: Bool { name == nil && collectorNumber == nil }
    /// What two frames must agree on to count as the same reading.
    var key: String { [name?.lowercased() ?? "", setCode ?? "", collectorNumber ?? ""].joined(separator: "|") }
}

nonisolated enum CardTextReader {
    /// The top band the title sits in, and the bottom band of the info
    /// block, as fractions of the card's height.
    static let titleBand: ClosedRange<CGFloat> = 0.84...1.0
    static let infoBand: ClosedRange<CGFloat> = 0.0...0.12

    static func read(_ lines: [RecognizedLine], knownSets: Set<String>) -> ScanReading {
        var reading = ScanReading()

        // Title: the highest confident line in the top band, left of the
        // mana cost.
        let titles = lines.filter { titleBand.contains($0.box.midY) && $0.box.minX < 0.5 && $0.confidence >= 0.3 }
            .sorted { $0.box.maxY > $1.box.maxY }
        for line in titles {
            let cleaned = cleanTitle(line.text)
            if cleaned.count >= 3 {
                reading.name = cleaned
                reading.nameConfidence = line.confidence
                break
            }
        }

        // Info block: bottom band, left side.
        let info = lines.filter { infoBand.contains($0.box.midY) && $0.box.minX < 0.6 }
            .sorted { $0.box.maxY > $1.box.maxY }
        for line in info {
            if reading.collectorNumber == nil, let number = collectorNumber(in: line.text) { reading.collectorNumber = number }
            if reading.setCode == nil, let code = setCode(in: line.text, knownSets: knownSets) {
                reading.setCode = code
                reading.language = language(in: line.text, after: code)
                reading.foil = foilMark(in: line.text, after: code)
            }
        }
        // A set code alone can't find a printing; a number alone can't either.
        if reading.setCode == nil { reading.collectorNumber = nil }
        return reading
    }

    /// "Lightning Bolt {R}" → "Lightning Bolt"; strips what OCR makes of
    /// mana pips at the end, stray punctuation, and doubled spaces.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Names are letters, spaces, and , ' - : ! ? / and accents.
        let allowed = CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: ",'’-:!?/&."))
        while let last = s.unicodeScalars.last, !CharacterSet.letters.contains(last) {
            s = String(s.unicodeScalars.dropLast())
        }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        // A trailing lone letter or two is a misread pip: "Sol Ring O".
        let words = s.split(separator: " ")
        var kept = words
        while kept.count > 1, let last = kept.last, last.count <= 1 { kept.removeLast() }
        s = kept.joined(separator: " ")
        return s.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
    }

    /// "0123/0280 R" → "123"; "045 U" → "45"; "123a" stays "123a".
    static func collectorNumber(in text: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])0*(\d{1,4}[a-z]?)(?:\s*/\s*\d{1,4})?(?:\s+[CURMSLTP])?(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let number = String(text[r])
        return number.isEmpty ? nil : number
    }

    /// The first word of 3–5 letters and digits that is a real set code
    /// ("DSK • EN" → "dsk").
    static func setCode(in text: String, knownSets: Set<String>) -> String? {
        let words = text.uppercased().split { !$0.isLetter && !$0.isNumber }
        for word in words where (3...5).contains(word.count) && word.contains(where: \.isLetter) {
            let code = word.lowercased()
            if knownSets.contains(code) { return code }
        }
        return nil
    }

    /// Printed language codes to Scryfall's ("JP" and "JA" are Japanese).
    static let languages: [String: String] = [
        "EN": "en", "JA": "ja", "JP": "ja", "DE": "de", "FR": "fr", "IT": "it", "ES": "es", "SP": "es",
        "PT": "pt", "RU": "ru", "KO": "ko", "KR": "ko", "CS": "zhs", "CT": "zht", "ZH": "zhs",
    ]

    /// "DSK • EN" → "en": the first language code after the set code.
    static func language(in text: String, after code: String) -> String? {
        let upper = text.uppercased()
        guard let range = upper.range(of: code.uppercased()) else { return nil }
        let rest = upper[range.upperBound...].split { !$0.isLetter }
        return rest.lazy.compactMap { languages[String($0)] }.first
    }

    /// The mark between set code and language: ★ (or what OCR makes of
    /// it) is foil, • nonfoil, nothing read is unknown.
    static func foilMark(in text: String, after code: String) -> Bool? {
        guard let range = text.range(of: code, options: .caseInsensitive) else { return nil }
        let between = text[range.upperBound...].prefix { !$0.isLetter }
        if between.contains(where: { "★☆*✦✧⋆".contains($0) }) { return true }
        if between.contains(where: { "•·.∙●◦".contains($0) }) { return false }
        return nil
    }

    /// 0–1: how alike two names are, case and accents aside (Levenshtein).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(fold(a)), y = Array(fold(b))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// A double-faced card's front name, folded for comparing.
    static func fold(_ s: String) -> String {
        (s.components(separatedBy: " // ").first ?? s)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
