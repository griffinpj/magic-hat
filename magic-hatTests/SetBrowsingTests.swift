import Testing
@testable import magic_hat

@Suite("Set browsing")
struct SetBrowsingTests {
    private let sets = [
        ScryfallSet(code: "dsk", name: "Duskmourn: House of Horror", setType: "expansion", releasedAt: "2024-09-27", cardCount: 286),
        ScryfallSet(code: "dsc", name: "Duskmourn Commander", setType: "commander", releasedAt: "2024-09-27", cardCount: 380),
        ScryfallSet(code: "blb", name: "Bloomburrow", setType: "expansion", releasedAt: "2024-08-02", cardCount: 280),
        ScryfallSet(code: "mkm", name: "Murders at Karlov Manor", setType: "expansion", releasedAt: "2024-02-09"),
        ScryfallSet(code: "ydsk", name: "Alchemy: Duskmourn", setType: "alchemy", releasedAt: "2024-11-12", digital: true),
        ScryfallSet(code: "tdsk", name: "Duskmourn Tokens", setType: "token", releasedAt: "2024-09-27"),
        ScryfallSet(code: "woe", name: "Wilds of Eldraine", setType: "expansion", releasedAt: "2023-09-08"),
    ]

    @Test func mainSetsByYearNewestFirst() {
        let sections = SetBrowsing.sections(sets, kind: .main, filter: "", digital: false)
        #expect(sections.map(\.year) == ["2024", "2023"])
        #expect(sections[0].sets.map(\.code) == ["dsk", "blb", "mkm"])
    }

    @Test func filterByNameOrCode() {
        #expect(SetBrowsing.sections(sets, kind: .all, filter: "dusk", digital: false).flatMap(\.sets).map(\.code).sorted() == ["dsc", "dsk", "tdsk"])
        #expect(SetBrowsing.sections(sets, kind: .all, filter: "WO", digital: false).flatMap(\.sets).map(\.code) == ["woe"])
        #expect(SetBrowsing.sections(sets, kind: .all, filter: "dusk", digital: true).flatMap(\.sets).count == 4, "digital on request")
    }

    @Test func kinds() {
        #expect(SetBrowsing.sections(sets, kind: .commander, filter: "", digital: false).flatMap(\.sets).map(\.code) == ["dsc"])
        #expect(SetBrowsing.sections(sets, kind: .tokens, filter: "", digital: false).flatMap(\.sets).map(\.code) == ["tdsk"])
        #expect(SetBrowsing.releaseDate("2024-09-27") != "2024-09-27")
    }
}
