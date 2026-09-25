import Testing
import Foundation
@testable import magic_hat

@Suite("LaunchPrewarm")
struct LaunchPrewarmTests {
    /// The prewarm list is kept by hand; this reads every symbol name out
    /// of the source so a new icon can't be added without joining it.
    @Test func symbolListCoversTheSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("magic-hat")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var used = Set<String>()
        let literal = try NSRegularExpression(pattern: #"system(?:Image|Name): "([^"]+)""#)
        let returned = try NSRegularExpression(pattern: #"var systemImage: String \{([\s\S]*?)\n    \}"#)
        let ret = try NSRegularExpression(pattern: #"return "([^"]+)""#)
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for m in literal.matches(in: text, range: range) {
                used.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
            for m in returned.matches(in: text, range: range) {
                let body = String(text[Range(m.range(at: 1), in: text)!])
                for r in ret.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    used.insert(String(body[Range(r.range(at: 1), in: body)!]))
                }
            }
        }
        let names = used.filter { $0.range(of: #"^[a-z0-9.]+$"#, options: .regularExpression) != nil }
        let missing = names.subtracting(LaunchPrewarm.symbolNames)
        #expect(missing.isEmpty, "add to LaunchPrewarm.symbolNames: \(missing.sorted())")
    }
}
