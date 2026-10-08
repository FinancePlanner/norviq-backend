import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief facts, prompt and draft")
struct MarketBriefPromptTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)

    private func news(_ headline: String, hoursAgo: Double) -> ProviderNewsItem {
        ProviderNewsItem(
            symbol: "", headline: headline, source: "Reuters", url: "https://example.com/\(headline.count)",
            summary: nil, image: nil, publishedAt: now.addingTimeInterval(-hoursAgo * 3600)
        )
    }

    private func facts() -> MarketBriefFacts {
        MarketBriefFacts.build(
            slot: .morning,
            tradingDate: "2026-10-08",
            quotes: [IndexQuote(symbol: "^GDAXI", price: 25032.36, previousClose: 25226.6, marketTime: now)],
            news: [news("German exports fell 0.8% in August", hoursAgo: 2), news("Old story", hoursAgo: 30)],
            earnings: [EarningsItemResponse(date: "2026-10-08", epsEstimate: 2.26, hour: "bmo", symbol: "PEP")],
            now: now
        )
    }

    @Test("Facts round quotes, name them from the catalog and drop news older than 24 h")
    func buildsFacts() {
        let facts = facts()
        #expect(facts.quotes == [MarketBriefFacts.Quote(symbol: "^GDAXI", name: "DAX", price: 25032.36, previousClose: 25226.6, changePercent: -0.77)])
        #expect(facts.headlines.map(\.title) == ["German exports fell 0.8% in August"])
        #expect(facts.earnings.map(\.symbol) == ["PEP"])
    }

    @Test("Grounded numbers cover quote prices, unsigned moves, earnings and headline figures")
    func groundedNumbers() {
        let grounded = facts().groundedNumbers
        #expect(grounded.contains(25032.36))
        #expect(grounded.contains(0.77))
        #expect(grounded.contains(2.26))
        #expect(grounded.contains(0.8))
        #expect(grounded.contains(25226.6))
    }

    @Test("Separator numbers are read both ways; years and small counts are not checked")
    func numberTokens() {
        let tokens = MarketBriefNumbers.tokens(in: "DAX 25.032, caiu 0,77% em 2027 com 6 clientes")
        #expect(tokens.count == 2)
        #expect(tokens[0].readings.contains(25032))
        #expect(tokens[0].readings.contains(25.032))
        #expect(tokens[1].readings.contains(0.77))
    }

    @Test("Whole numbers are checked when they look like a level, a percentage or money")
    func wholeNumberTokens() {
        #expect(MarketBriefNumbers.tokens(in: "DAX at 24150").map(\.readings) == [[24150]])
        #expect(MarketBriefNumbers.tokens(in: "fell 2% today").map(\.readings) == [[2]])
        #expect(MarketBriefNumbers.tokens(in: "a $40B deal").map(\.readings) == [[40]])
        #expect(MarketBriefNumbers.tokens(in: "DAX a 24\u{00A0}150 pontos").map(\.readings) == [[24150]])
        #expect(MarketBriefNumbers.tokens(in: "em 2027 com 6 clientes e 36 fábricas").isEmpty)
    }

    @Test("Revenue estimates are grounded in billions and millions too")
    func revenueScaled() {
        let facts = MarketBriefFacts.build(
            slot: .morning, tradingDate: "2026-10-08", quotes: [], news: [],
            earnings: [EarningsItemResponse(revenueEstimate: 40_500_000_000, symbol: "PEP")], now: now
        )
        #expect(facts.groundedNumbers.contains(40.5))
        #expect(facts.groundedNumbers.contains(40500))
    }

    @Test("Without web search the model is asked for a short brief, so the fallback chain's token budget fits")
    func offlineIsShort() throws {
        let offline = try MarketBriefPrompt.messages(facts: facts(), webSearch: false)
        #expect(offline[1].content?.contains("at most 5 items") == true)
        #expect(offline[1].content?.contains("under 300 characters") == true)
    }

    @Test("Messages carry the fixed system prompt and the facts; web search changes only the user turn")
    func messages() throws {
        let web = try MarketBriefPrompt.messages(facts: facts(), webSearch: true)
        let offline = try MarketBriefPrompt.messages(facts: facts(), webSearch: false)
        #expect(web.count == 2)
        #expect(web[0].role == "system")
        #expect(web[0].content == MarketBriefPrompt.systemPrompt)
        #expect(offline[0].content == MarketBriefPrompt.systemPrompt)
        #expect(web[1].content?.contains("\"tradingDate\":\"2026-10-08\"") == true)
        #expect(web[1].content?.contains("Use web search") == true)
        #expect(offline[1].content?.contains("Web search is unavailable") == true)
    }

    @Test("Draft parsing survives code fences and a leading sentence")
    func parsesFencedDraft() throws {
        let content = """
        Here is the brief:
        ```json
        {"en":{"greeting":"Good morning,","items":[{"kind":"highlight","text":"Risk-off.","tickers":[],"sourceUrl":null}]},
         "pt-PT":{"greeting":"Bom dia,","items":[{"kind":"highlight","text":"Risk-off.","tickers":["$PEP"],"sourceUrl":null}]}}
        ```
        """
        let draft = try MarketBriefDraft.parse(content)
        #expect(draft.section(.en).greeting == "Good morning,")
        #expect(draft.section(.ptPT).items.first?.tickers == ["$PEP"])
    }

    @Test("Draft parsing fails clearly without a JSON object")
    func rejectsNonJSON() {
        #expect(throws: MarketBriefError.unparseableDraft) {
            try MarketBriefDraft.parse("I could not find any news today.")
        }
    }
}
