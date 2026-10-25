import Testing
import Foundation
@testable import magic_hat

/// A web page is never a deck list, however it spells its tags or says
/// what it is in its headers.
@Suite("DeckSite HTML")
struct DeckSiteHTMLTests {
    @Test func htmlIsRefusedInAnyCase() {
        for page in ["<HTML><body>4 Lightning Bolt</body></HTML>", "<!doctype html>\n4 Lightning Bolt", "  <Html lang=\"en\">4 Lightning Bolt"] {
            #expect(throws: DeckSiteError.notAList) {
                try DeckSiteClient.plainText(Data(page.utf8), splitSideboardAtBlankLine: false)
            }
        }
    }

    @Test func aTextHTMLContentTypeIsRefusedEvenWithoutTags() throws {
        let list = Data("4 Lightning Bolt\n20 Mountain".utf8)
        #expect(throws: DeckSiteError.notAList) {
            try DeckSiteClient.plainText(list, splitSideboardAtBlankLine: false, contentType: "Text/HTML; charset=utf-8")
        }
        let plain = try DeckSiteClient.plainText(list, splitSideboardAtBlankLine: false, contentType: "text/plain; charset=utf-8")
        #expect(plain.text.contains("Lightning Bolt"))
    }
}
