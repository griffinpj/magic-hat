//
//  CSVParser.swift
//  magic-hat
//
//  Minimal RFC-4180-ish CSV reader (handles quoted fields, embedded commas,
//  escaped quotes, CRLF) plus a mapper from ManaBox columns to ManaBoxRow.
//  Kept generic in Utils; ManaBox-specific mapping is a small extension.
//

import Foundation

nonisolated enum CSVParser {
    /// Parses CSV text into an array of string arrays (rows of fields).
    ///
    /// Iterates over Unicode scalars rather than Characters: a CRLF ("\r\n")
    /// is a single Swift `Character` (grapheme cluster), so matching on
    /// Characters would swallow line breaks and collapse the file into one
    /// giant row. Scalars keep `\r` and `\n` separate.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            // Skip blank lines.
            if !(record.count == 1 && record[0].isEmpty) {
                rows.append(record)
            }
            record = []
        }

        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let newline: Unicode.Scalar = "\n"
        let carriage: Unicode.Scalar = "\r"

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case quote: inQuotes = true
                case comma: endField()
                case newline: endRecord()
                case carriage: break // part of CRLF; the \n ends the record
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        // Flush trailing field/record without newline.
        if !field.isEmpty || !record.isEmpty {
            endRecord()
        }
        return rows
    }
}

// MARK: - ManaBox mapping

nonisolated enum ManaBoxParseError: Error, LocalizedError {
    case empty
    case unexpectedHeader([String])

    var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .unexpectedHeader:
            return "This doesn't look like a ManaBox export (unexpected columns)."
        }
    }
}

nonisolated extension CSVParser {
    private static let isoFormatter = ISO8601DateFormatter()

    /// Parses ManaBox CSV text into rows, validating the header.
    static func parseManaBox(_ text: String) throws -> [ManaBoxRow] {
        let rows = parse(text)
        guard let header = rows.first else { throw ManaBoxParseError.empty }

        // Index columns by trimmed header name so order changes are tolerated.
        // Keep the first occurrence if a header ever repeats a column, so a
        // malformed file surfaces as a clean error rather than a crash.
        let idx = Dictionary(
            header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Require the essential columns.
        let required = ["Name", "Scryfall ID", "Quantity", "Binder Name"]
        guard required.allSatisfy({ idx[$0] != nil }) else {
            throw ManaBoxParseError.unexpectedHeader(header)
        }

        func value(_ fields: [String], _ column: String) -> String {
            guard let i = idx[column], i < fields.count else { return "" }
            return fields[i]
        }

        return rows.dropFirst().compactMap { fields -> ManaBoxRow? in
            let scryfallID = value(fields, "Scryfall ID").trimmingCharacters(in: .whitespaces)
            guard !scryfallID.isEmpty else { return nil }

            let priceStr = value(fields, "Purchase price")
            let addedStr = value(fields, "Added")

            return ManaBoxRow(
                binderName: value(fields, "Binder Name"),
                binderType: value(fields, "Binder Type"),
                name: value(fields, "Name"),
                setCode: value(fields, "Set code"),
                setName: value(fields, "Set name"),
                collectorNumber: value(fields, "Collector number"),
                foil: value(fields, "Foil"),
                rarity: value(fields, "Rarity"),
                quantity: Int(value(fields, "Quantity")) ?? 0,
                manaBoxID: value(fields, "ManaBox ID"),
                scryfallID: scryfallID,
                purchasePrice: Double(priceStr),
                misprint: value(fields, "Misprint").lowercased() == "true",
                altered: value(fields, "Altered").lowercased() == "true",
                condition: value(fields, "Condition"),
                language: value(fields, "Language"),
                purchasePriceCurrency: value(fields, "Purchase price currency"),
                added: isoFormatter.date(from: addedStr)
            )
        }
    }
}
