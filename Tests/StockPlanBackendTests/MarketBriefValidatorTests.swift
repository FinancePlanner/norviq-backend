import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief validator")
struct MarketBriefValidatorTests {
    private func item(_ text: String, kind: String = "highlight", tickers: [String]? = nil, source: String? = nil) -> MarketBriefDraft.Item {
        MarketBriefDraft.Item(kind: kind, text: text, tickers: tickers, sourceUrl: source)
    }

    private func section(_ items: [MarketBriefDraft.Item], greeting: String? = "Bom dia,") -> MarketBriefDraft.Section {
        MarketBriefDraft.Section(greeting: greeting, items: items)
    }

    private let filler = [
        MarketBriefDraft.Item(kind: "highlight", text: "Tom de cautela na Europa.", tickers: nil, sourceUrl: nil),
        MarketBriefDraft.Item(kind: "highlight", text: "Investidores atentos à Fed.", tickers: nil, sourceUrl: nil),
        MarketBriefDraft.Item(kind: "highlight", text: "Petróleo em foco.", tickers: nil, sourceUrl: nil),
    ]

    @Test("An unsourced number that matches a fact is kept, in either number format")
    func groundedNumberKept() throws {
        let output = try MarketBriefValidator.validate(
            section([item("O DAX cai 0,77% para 25.032 pontos.")] + filler),
            slot: .morning, language: .ptPT, grounded: [25032.36, 0.77]
        )
        #expect(output.items.count == 4)
        #expect(output.dropped == 0)
    }

    @Test("An unsourced invented number drops that item only")
    func inventedNumberDropped() throws {
        let output = try MarketBriefValidator.validate(
            section([item("O Brent negoceia perto de 104,50 dólares.")] + filler),
            slot: .morning, language: .ptPT, grounded: [25032.36, 0.77]
        )
        #expect(output.items.count == 3)
        #expect(output.dropped == 1)
    }

    @Test("A sourced number is kept even if it is not in the facts")
    func sourcedNumberKept() throws {
        let output = try MarketBriefValidator.validate(
            section([item("Brent near $104.50.", source: "https://www.reuters.com/markets/oil")] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items.first?.sourceUrl == "https://www.reuters.com/markets/oil")
        #expect(output.dropped == 0)
    }

    @Test("A non-https source does not count as a source")
    func httpSourceIgnored() throws {
        let output = try MarketBriefValidator.validate(
            section([item("Brent near $104.50.", source: "http://example.com/x")] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.dropped == 1)
    }

    @Test("Wrong kind for the slot, empty text and over-long text are dropped")
    func shapeRules() throws {
        let long = String(repeating: "a", count: 401)
        let output = try MarketBriefValidator.validate(
            section([item("A story.", kind: "story"), item("   "), item(long)] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items.count == 3)
        #expect(output.dropped == 3)
    }

    @Test("Evening stories may run to 1000 characters")
    func eveningLength() throws {
        let story = String(repeating: "b", count: 950)
        let stories = (0 ..< 3).map { _ in item(story, kind: "story") }
        let output = try MarketBriefValidator.validate(section(stories, greeting: nil), slot: .evening, language: .en, grounded: [])
        #expect(output.items.count == 3)
    }

    @Test("Fewer than three surviving items rejects the language")
    func tooFew() {
        #expect(throws: MarketBriefError.tooFewItems(language: "en", kept: 2)) {
            try MarketBriefValidator.validate(section(Array(filler.prefix(2))), slot: .morning, language: .en, grounded: [])
        }
    }

    @Test("Tickers are uppercased, stripped of $, deduplicated and filtered")
    func tickers() throws {
        let output = try MarketBriefValidator.validate(
            section([item("$NVDA and $BRK.B lead.", tickers: ["$nvda", "NVDA", "BRK.B", "TOOLONGX", "1AB"])] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items[0].tickers == ["NVDA", "BRK.B"])
    }

    @Test("Morning keeps at most 10 items, evening at most 8")
    func itemCaps() throws {
        let many = (0 ..< 12).map { _ in item("Line.") }
        let morning = try MarketBriefValidator.validate(section(many), slot: .morning, language: .en, grounded: [])
        #expect(morning.items.count == 10)
        let stories = (0 ..< 12).map { _ in item("Story.", kind: "story") }
        let evening = try MarketBriefValidator.validate(section(stories), slot: .evening, language: .en, grounded: [])
        #expect(evening.items.count == 8)
    }

    @Test("Blank greeting becomes nil")
    func blankGreeting() throws {
        let output = try MarketBriefValidator.validate(section(filler, greeting: "  "), slot: .morning, language: .en, grounded: [])
        #expect(output.greeting == nil)
    }
}
