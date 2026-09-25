import Testing
import Foundation
import UIKit
@testable import magic_hat

@Suite("LaunchPrewarm")
struct LaunchPrewarmTests {
    /// The prewarm list is kept by hand; this reads every symbol name out
    /// of the source so a new icon can't be added without joining it. A
    /// name the prewarm misses is resolved from disk on the main thread the
    /// first time it is drawn — 0.22s opening a deck, for the Lock item's
    /// "lock", a ternary the earlier `systemImage: "…"` match didn't see.
    @Test func symbolListCoversTheSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("magic-hat")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var used = Set<String>()
        // Every literal on a line naming a symbol, ternaries included.
        let symbolLine = try NSRegularExpression(pattern: #"system(?:Image|Name):"#)
        let literal = try NSRegularExpression(pattern: #""([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
        // Computed names, at any indentation.
        let returned = try NSRegularExpression(pattern: #"var (?:systemImage|icon): String \{([\s\S]*?)\n\s*\}\n"#)
        let ret = try NSRegularExpression(pattern: #"return "([^"]+)""#)
        // `.symbolVariant(...)` draws "name.circle" and "name.circle.fill",
        // not the name in the Label above it.
        let variant = try NSRegularExpression(pattern: #"\.(circle\.fill|circle|fill|square\.fill|square|slash)\b"#)
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard symbolLine.firstMatch(in: line, range: range) != nil else { continue }
                let names = literal.matches(in: line, range: range).map { String(line[Range($0.range(at: 1), in: line)!]) }
                used.formUnion(names)
                // A variant modifier within the next few lines.
                for next in lines[(i + 1)..<min(i + 4, lines.count)] where next.contains(".symbolVariant(") {
                    let r = NSRange(next.startIndex..., in: next)
                    for m in variant.matches(in: next, range: r) {
                        let suffix = String(next[Range(m.range(at: 1), in: next)!])
                        used.formUnion(names.map { "\($0).\(suffix)" })
                    }
                }
            }
            let range = NSRange(text.startIndex..., in: text)
            for m in returned.matches(in: text, range: range) {
                let body = String(text[Range(m.range(at: 1), in: text)!])
                for r in ret.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    used.insert(String(body[Range(r.range(at: 1), in: body)!]))
                }
            }
        }
        // Only real symbols: a literal on a symbol line may be anything.
        let symbols = used.filter { UIImage(systemName: $0) != nil }
        let missing = symbols.subtracting(LaunchPrewarm.symbolNames)
        #expect(missing.isEmpty, "add to LaunchPrewarm.symbolNames: \(missing.sorted())")
    }

    /// An empty name is looked up like any other, fails, and logs.
    @Test func noEmptySymbolNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("magic-hat")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let empty = try NSRegularExpression(pattern: #"system(?:Image|Name):[^\n]*"""#)
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if empty.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "empty SF Symbol name in \(offenders)")
    }
}
