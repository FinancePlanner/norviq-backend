import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("PortfolioValuationService")
struct PortfolioValuationServiceTests {
    private struct StubMarketDataService: MarketDataService {
        let quotesBySymbol: [String: QuoteResponse]
        let failBatch: Bool

        init(quotesBySymbol: [String: QuoteResponse] = [:], failBatch: Bool = false) {
            self.quotesBySymbol = quotesBySymbol
            self.failBatch = failBatch
        }

        var fmpProvider: (any FMPMarketDataProvider)? {
            nil
        }

        func quote(symbol: String, on _: Request) async throws -> QuoteResponse {
            guard !failBatch, let quote = quotesBySymbol[symbol.uppercased()] else {
                throw Abort(.badGateway, reason: "quote unavailable")
            }
            return quote
        }

        func quoteBatch(symbols: [String], on req: Request) async throws -> QuoteBatchResponse {
            guard !failBatch else { throw Abort(.badGateway, reason: "provider down") }
            var quotes: [QuoteResponse] = []
            for symbol in symbols {
                if let quote = try? await quote(symbol: symbol, on: req) {
                    quotes.append(quote)
                }
            }
            return QuoteBatchResponse(quotes: quotes)
        }

        func history(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func archivedHistory(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func refreshHistory(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func search(query _: String, on _: Request) async throws -> [SearchResultResponse] {
            throw Abort(.notImplemented)
        }

        func fx(pair _: String, on _: Request) async throws -> FxRateResponse {
            throw Abort(.notImplemented)
        }

        func profile(symbol _: String, on _: Request) async throws -> CompanyProfileResponse {
            throw Abort(.notImplemented)
        }

        func basicFinancials(symbol _: String, on _: Request) async throws -> BasicFinancialsResponse {
            throw Abort(.notImplemented)
        }

        func analysis(symbol _: String, on _: Request) async throws -> StockAnalysisMetricsResponse {
            throw Abort(.notImplemented)
        }

        func compare(symbols _: [String], on _: Request) async throws -> [StockAnalysisMetricsResponse] {
            throw Abort(.notImplemented)
        }

        func cashFlowStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [CashFlowStatementResponse] {
            throw Abort(.notImplemented)
        }

        func incomeStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [IncomeStatementResponse] {
            throw Abort(.notImplemented)
        }

        func balanceSheetStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [BalanceSheetStatementResponse] {
            throw Abort(.notImplemented)
        }

        func ratiosTTM(symbol _: String, on _: Request) async throws -> [RatiosTTMResponse] {
            throw Abort(.notImplemented)
        }

        func gradesConsensus(symbol _: String, on _: Request) async throws -> [GradesConsensusResponse] {
            throw Abort(.notImplemented)
        }

        func financialGrowth(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [FinancialGrowthResponse] {
            throw Abort(.notImplemented)
        }

        func analystEstimates(symbol _: String, period _: String, page _: Int?, limit _: Int?, on _: Request) async throws -> [AnalystEstimatesResponse] {
            throw Abort(.notImplemented)
        }

        func ratios(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [RatiosResponse] {
            throw Abort(.notImplemented)
        }

        func earnings(symbol _: String, limit _: Int?, on _: Request) async throws -> [EarningsResponse] {
            throw Abort(.notImplemented)
        }

        func earningsCalendar(from _: String?, to _: String?, on _: Request) async throws -> [EarningsResponse] {
            throw Abort(.notImplemented)
        }

        func earningsTranscript(symbol _: String, date _: String?, year _: Int?, quarter _: Int?, on _: Request) async throws -> EarningsTranscriptResponse {
            throw Abort(.notImplemented)
        }

        func historicalSectorPerformance(sector _: String, exchange _: String?, from _: String?, to _: String?, on _: Request) async throws -> [HistoricalSectorPerformanceResponse] {
            throw Abort(.notImplemented)
        }

        func priceChart(symbol _: String, range _: String, on _: Request) async throws -> PriceChartSeries {
            throw Abort(.notImplemented)
        }

        func priceChartComparison(symbols _: [String], range _: String, on _: Request) async throws -> PriceChartComparisonResponse {
            throw Abort(.notImplemented)
        }
    }

    /// Minimal app for exercising the valuation service without touching a
    /// database: the service only reads `req.application.marketDataService`
    /// and `req.logger`, both of which work on a bare `.testing` application.
    private func withApp(marketDataService: any MarketDataService, _ test: (Application, Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.marketDataService = marketDataService
        let request = Request(application: app, on: app.eventLoopGroup.next())
        do {
            try await test(app, request)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func makeStock(symbol: String, shares: Double, buyPrice: Double) -> Stock {
        Stock(
            userId: UUID(),
            portfolioListId: UUID(),
            symbol: symbol,
            shares: shares,
            buyPrice: buyPrice,
            buyDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Values a holding with a live quote")
    func quotePresent() async throws {
        let service = DefaultPortfolioValuationService()
        let stub = StubMarketDataService(quotesBySymbol: [
            "AAPL": QuoteResponse(symbol: "AAPL", currency: "USD", currentPrice: 200, change: 2, percentChange: 1.0, timestamp: 1_700_000_000),
        ])

        try await withApp(marketDataService: stub) { _, req in
            let stocks = [makeStock(symbol: "AAPL", shares: 10, buyPrice: 150)]
            let valuation = try await service.value(stocks: stocks, cashBalance: 0, asOf: Date(), on: req)

            #expect(valuation.holdings.count == 1)
            let holding = try #require(valuation.holdings.first)
            #expect(holding.symbol == "AAPL")
            #expect(holding.shares == 10)
            #expect(holding.costBasis == 1500)
            #expect(holding.averageBuyPrice == 150)
            #expect(holding.currentPrice == 200)
            #expect(holding.marketValue == 2000)
            #expect(holding.unrealizedPnl == 500)
            #expect(holding.unrealizedPnlPercent.map { abs($0 - 33.33) < 0.01 } == true)
            #expect(holding.dayChange == 20)
            #expect(holding.dayChangePercent == 1.0)
            #expect(holding.hasLiveQuote == true)
            #expect(valuation.totalValue == 2000)
        }
    }

    @Test("Falls back to cost basis when no quote is available, unrealized pnl is zero")
    func quoteMissingFallsBack() async throws {
        let service = DefaultPortfolioValuationService()
        // No quote registered for NVDA at all: the stub's quoteBatch succeeds
        // but returns an empty quotes array (best-effort partial coverage).
        let stub = StubMarketDataService(quotesBySymbol: [:])

        try await withApp(marketDataService: stub) { _, req in
            let stocks = [makeStock(symbol: "NVDA", shares: 4, buyPrice: 500)]
            let valuation = try await service.value(stocks: stocks, cashBalance: 0, asOf: Date(), on: req)

            let holding = try #require(valuation.holdings.first)
            #expect(holding.currentPrice == nil)
            #expect(holding.hasLiveQuote == false)
            #expect(holding.costBasis == 2000)
            #expect(holding.marketValue == 2000)
            #expect(holding.unrealizedPnl == 0)
            #expect(holding.dayChange == nil)
            #expect(holding.dayChangePercent == nil)
        }
    }

    @Test("Merges multiple lots of the same symbol into a weighted average buy price")
    func mergesMultipleLots() async throws {
        let service = DefaultPortfolioValuationService()
        let stub = StubMarketDataService(quotesBySymbol: [
            "AAPL": QuoteResponse(symbol: "AAPL", currency: "USD", currentPrice: 200, change: nil, percentChange: nil, timestamp: 1_700_000_000),
        ])

        try await withApp(marketDataService: stub) { _, req in
            // 10 @ 100 and 10 @ 200 -> 20 shares, cost basis 3000, avg buy price 150.
            let stocks = [
                makeStock(symbol: "AAPL", shares: 10, buyPrice: 100),
                makeStock(symbol: "aapl", shares: 10, buyPrice: 200),
            ]
            let valuation = try await service.value(stocks: stocks, cashBalance: 0, asOf: Date(), on: req)

            #expect(valuation.holdings.count == 1)
            let holding = try #require(valuation.holdings.first)
            #expect(holding.shares == 20)
            #expect(holding.costBasis == 3000)
            #expect(holding.averageBuyPrice == 150)
            #expect(holding.marketValue == 4000)
        }
    }

    @Test("Empty input produces an empty, zeroed valuation")
    func emptyInput() async throws {
        let service = DefaultPortfolioValuationService()
        let stub = StubMarketDataService()

        try await withApp(marketDataService: stub) { _, req in
            let valuation = try await service.value(stocks: [], cashBalance: 500, asOf: Date(), on: req)

            #expect(valuation.holdings.isEmpty)
            #expect(valuation.holdingsMarketValue == 0)
            #expect(valuation.totalCost == 0)
            #expect(valuation.unrealizedPnl == 0)
            #expect(valuation.unrealizedPnlPercent == nil)
            #expect(valuation.dayChange == 0)
            #expect(valuation.cashBalance == 500)
            #expect(valuation.totalValue == 500)
            // No holdings means no day change, but cash still makes the prior
            // total value positive, so the percent is a defined 0 (not nil).
            #expect(valuation.dayChangePercent == 0)
        }
    }

    @Test("Sums per-holding day change and derives portfolio day change percent from the prior total value")
    func dayChangeAggregation() async throws {
        let service = DefaultPortfolioValuationService()
        let stub = StubMarketDataService(quotesBySymbol: [
            "AAPL": QuoteResponse(symbol: "AAPL", currency: "USD", currentPrice: 200, change: 2, percentChange: 1.01, timestamp: 1_700_000_000),
            "MSFT": QuoteResponse(symbol: "MSFT", currency: "USD", currentPrice: 400, change: -4, percentChange: -0.99, timestamp: 1_700_000_000),
        ])

        try await withApp(marketDataService: stub) { _, req in
            let stocks = [
                makeStock(symbol: "AAPL", shares: 20, buyPrice: 150), // dayChange = 2*20 = 40
                makeStock(symbol: "MSFT", shares: 5, buyPrice: 300), // dayChange = -4*5 = -20
            ]
            let valuation = try await service.value(stocks: stocks, cashBalance: 0, asOf: Date(), on: req)

            // Total market value: 20*200 + 5*400 = 4000 + 2000 = 6000; dayChange sum = 20.
            #expect(valuation.dayChange == 20)
            #expect(valuation.totalValue == 6000)
            // previous total value = 6000 - 20 = 5980; dayChangePercent = 20/5980*100
            let expectedPercent = (20.0 / 5980.0) * 100
            #expect(valuation.dayChangePercent.map { abs($0 - expectedPercent) < 0.0001 } == true)
        }
    }

    @Test("Quote batch failure degrades gracefully to cost-basis valuation")
    func quoteBatchThrows() async throws {
        let service = DefaultPortfolioValuationService()
        let stub = StubMarketDataService(failBatch: true)

        try await withApp(marketDataService: stub) { _, req in
            let stocks = [makeStock(symbol: "TSLA", shares: 3, buyPrice: 250)]
            let valuation = try await service.value(stocks: stocks, cashBalance: 100, asOf: Date(), on: req)

            let holding = try #require(valuation.holdings.first)
            #expect(holding.currentPrice == nil)
            #expect(holding.hasLiveQuote == false)
            #expect(holding.marketValue == 750)
            #expect(holding.unrealizedPnl == 0)
            #expect(valuation.totalValue == 850)
        }
    }
}
