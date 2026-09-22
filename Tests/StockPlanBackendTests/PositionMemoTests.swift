import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Position memos")
struct PositionMemoTests {
    @Test("The GRAB ask parses the listing, the cost, and the stated drawdown")
    func parsesGrabAsk() throws {
        let ask = PositionMemoAsk.parse(
            "Make DD about $GRAB (A6I), my average price is 4.1 euros and im down 34% so far"
        )
        let parsed = try #require(ask)
        #expect(parsed.askedSymbol == "A6I")
        #expect(parsed.companionSymbol == "GRAB")
        #expect(parsed.cost == 4.1)
        #expect(parsed.costCurrency == "EUR")
        #expect(parsed.statedPercent == -34)
    }

    @Test("A spending question is not a memo")
    func ignoresBudgetQuestion() {
        #expect(PositionMemoAsk.parse("what's my budget") == nil)
        #expect(PositionMemoAsk.parse("should I sell") == nil)
        #expect(PositionMemoAsk.parse("/expenses this month") == nil)
    }

    @Test("Slash dd and a stance aimed at a ticker are memos")
    func routesExplicitAsks() throws {
        let slash = try #require(PositionMemoAsk.parse("/dd GRAB"))
        #expect(slash.askedSymbol == "GRAB")
        let stance = try #require(PositionMemoAsk.parse("should I sell AAPL"))
        #expect(stance.askedSymbol == "AAPL")
        let expanded = try #require(PositionMemoAsk.parse("Write a due diligence memo. GRAB cost 4.10 EUR"))
        #expect(expanded.askedSymbol == "GRAB")
        #expect(expanded.cost == 4.10)
        #expect(expanded.costCurrency == "EUR")
    }

    @Test("Live drawdown, the stated mark, and breakeven are server arithmetic")
    func markMathMatchesTheFixture() throws {
        let mark = PositionMemoMath.mark(PositionMemoMath.Input(
            askedSymbol: "A6I",
            primarySymbol: "GRAB",
            statedCost: 4.10,
            statedCurrency: "EUR",
            statedPercent: -34,
            live: .init(symbol: "A6I", price: 2.77, currency: "EUR"),
            primary: .init(symbol: "GRAB", price: 3.16, currency: "USD"),
            fxRate: nil,
            fxPair: nil,
            fxDate: nil,
            shares: nil,
            lotAveragePrice: nil
        ))
        #expect(mark.costSource == "stated")
        #expect(try PositionMemoMath.oneDecimal(#require(mark.drawdownPercent)) == -32.4)
        #expect(try PositionMemoMath.threeDecimal(#require(mark.priceImpliedByStatedPercent)) == 2.706)
        #expect(try PositionMemoMath.oneDecimal(#require(mark.breakevenPercent)) == 48.0)
        #expect(mark.priceInCostCurrency == 2.77)
    }

    @Test("A dollar quote is converted into the euro cost with the supplied rate")
    func convertsWithFX() throws {
        let mark = PositionMemoMath.mark(PositionMemoMath.Input(
            askedSymbol: "GRAB",
            primarySymbol: "GRAB",
            statedCost: 4.10,
            statedCurrency: "EUR",
            statedPercent: nil,
            live: .init(symbol: "GRAB", price: 3.16, currency: "USD"),
            primary: nil,
            fxRate: 0.87,
            fxPair: "USDEUR",
            fxDate: "2026-09-22",
            shares: 10,
            lotAveragePrice: 5
        ))
        let converted = try #require(mark.priceInCostCurrency)
        #expect(abs(converted - (3.16 * 0.87)) < 0.000_001)
        #expect(mark.fxRate == 0.87)
        #expect(mark.lotAveragePrice == 5)
        #expect(mark.costSource == "stated")
    }

    @Test("The writer is one JSON completion over the pack, with no tools")
    func writerRequestCarriesThePack() throws {
        var pack = emptyPack()
        pack.income = [.init(date: "2025-12-31", fiscalYear: "2025", revenue: 100, operatingIncome: 2, netIncome: 10, interestIncome: 8, epsDiluted: 0.11)]
        let mark = PositionMemoMath.mark(PositionMemoMath.Input(
            askedSymbol: "GRAB", primarySymbol: "GRAB", statedCost: 4.1, statedCurrency: "EUR",
            statedPercent: -34, live: .init(symbol: "GRAB", price: 2.77, currency: "EUR"),
            primary: nil, fxRate: nil, fxPair: nil, fxDate: nil, shares: nil, lotAveragePrice: nil
        ))
        let messages = try PositionMemoWriter.messages(pack: pack, mark: mark)
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.toolCalls == nil })
        let user = try #require(messages.last?.content)
        #expect(user.contains("EVIDENCE PACK"))
        #expect(user.contains("\"revenue\":100"))
        #expect(!user.contains("tool_choice"))
    }

    @Test("A missing income statement is replaced with the unavailable section")
    func missingIncomeDropsInventedRevenue() {
        let draft = PositionMemoDraft(
            title: "GRAB",
            verdict: "Q would not add here.",
            sections: [
                PositionMemoSection(heading: "The business", paragraphs: ["Revenue was $3.7 billion."]),
                PositionMemoSection(heading: "Your mark", paragraphs: ["Ignore this."]),
            ]
        )
        let guarded = PositionMemoDraftGuard.apply(draft, pack: emptyPack())
        let business = guarded.sections.first { $0.heading == "The business" }
        #expect(business?.paragraphs == [PositionMemoCopy.unavailableBusiness])
        let body = guarded.sections.flatMap(\.paragraphs).joined(separator: " ")
        #expect(!body.contains("$"))
        #expect(guarded.sections.allSatisfy { $0.heading != "Your mark" })
    }

    private func emptyPack() -> PositionMemoPack {
        PositionMemoPack(
            askedSymbol: "GRAB",
            primarySymbol: "GRAB",
            listings: [],
            quotes: [],
            fx: nil,
            profile: nil,
            income: [],
            balance: nil,
            cashFlow: nil,
            ratios: nil,
            growth: nil,
            estimates: [],
            grades: nil,
            technicals: nil,
            insider: nil,
            news: [],
            nextEarningsDate: nil,
            holding: nil,
            notes: [],
            targets: [],
            basicMetrics: [:],
            unavailable: ["income-statement"]
        )
    }
}
