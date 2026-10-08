import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief generator")
struct MarketBriefGeneratorTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)
    private let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)

    private func generator(
        quotes: [IndexQuote],
        web: ScriptedBriefChatClient?,
        fallback: ScriptedBriefChatClient
    ) -> MarketBriefGenerator {
        MarketBriefGenerator(
            quotes: StubIndexQuoteProvider(result: quotes),
            news: nil,
            earnings: StubEarningsService(),
            webClient: web,
            webModel: "anthropic/claude-haiku-4.5:online",
            fallbackClient: { fallback },
            now: { [now] in now }
        )
    }

    private var dax: IndexQuote {
        IndexQuote(symbol: "^GDAXI", price: 25032.36, previousClose: 25226.6, marketTime: now)
    }

    @Test("Web search success: both languages, formatted rows, not degraded")
    func webSuccess() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        let fallback = ScriptedBriefChatClient([])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.model == "anthropic/claude-haiku-4.5:online")
            #expect(brief.responses.map(\.language) == ["en", "pt-PT"])
            #expect(brief.responses.allSatisfy { !$0.degraded && $0.items.count == 5 })
            let pt = try #require(brief.responses.last)
            #expect(pt.groups.first?.rows.first?.level == "25.032")
            #expect(pt.greeting == "Bom dia,")
            #expect(pt.tradingDate == "2026-10-08")
            #expect(pt.slot == .morning)
            #expect(fallback.calls.isEmpty)
            #expect(web.calls.first?.last?.content?.contains("Use web search") == true)
        }
    }

    @Test("Web failure falls back to the chain without web search and marks the brief degraded")
    func webFailureFallsBack() async throws {
        let web = ScriptedBriefChatClient([.failure(Abort(.paymentRequired))])
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy { $0.degraded })
            #expect(brief.model == "fallback-chain")
            #expect(fallback.calls.first?.last?.content?.contains("Web search is unavailable") == true)
        }
    }

    @Test("A web draft that fails validation also falls back")
    func invalidWebDraftFallsBack() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON(count: 2))])
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy { $0.degraded })
        }
    }

    @Test("No web client configured goes straight to the fallback")
    func noWebClient() async throws {
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: nil, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy { $0.degraded })
            #expect(fallback.calls.count == 1)
        }
    }

    @Test("Both attempts failing throws")
    func bothFail() async throws {
        let web = ScriptedBriefChatClient([.content("no json here")])
        let fallback = ScriptedBriefChatClient([.failure(Abort(.badGateway))])
        try await MarketBriefFixtures.withRequest { req in
            await #expect(throws: (any Error).self) {
                try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            }
        }
    }

    @Test("No fresh quotes (holiday, Yahoo blocked) still produces a text-only brief")
    func noQuotes() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [], web: web, fallback: ScriptedBriefChatClient([])).generate(due, on: req)
            #expect(brief.responses.allSatisfy { $0.groups.isEmpty && $0.items.count == 5 })
        }
    }
}
