import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Insider activity and cluster buys")
struct InsiderActivityTests {
    // MARK: - Fixtures

    /// `asOf` for every fixture below. Fixed so the 365-day window never moves
    /// under the test.
    private static let asOf: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components) ?? Date()
    }()

    private func wire(
        date: String,
        name: String,
        type: String = "P-Purchase",
        shares: Double = 1000,
        price: Double? = 10,
        title: String? = "Chief Executive Officer",
        owned: Double? = 5000,
        url: String? = "https://sec.gov/filing"
    ) -> FMPInsiderTrade {
        FMPInsiderTrade(
            symbol: "AAPL",
            filingDate: date,
            transactionDate: date,
            transactionType: type,
            securitiesTransacted: shares,
            securitiesOwned: owned,
            price: price,
            reportingName: name,
            typeOfOwner: title,
            acquisitionOrDisposition: nil,
            url: url
        )
    }

    private func build(_ wire: [FMPInsiderTrade], windowDays: Int = 365) -> InsiderActivityResponse {
        InsiderActivity.build(
            symbol: "AAPL",
            windowDays: windowDays,
            wire: wire,
            asOf: Self.asOf
        )
    }

    // MARK: - Transaction-type → kind

    @Test(
        "Transaction codes map to buy, sell, award, or other",
        arguments: [
            ("P-Purchase", InsiderTradeKind.buy),
            ("P", InsiderTradeKind.buy),
            ("p-purchase", InsiderTradeKind.buy),
            ("S-Sale", InsiderTradeKind.sell),
            ("S", InsiderTradeKind.sell),
            ("A-Award", InsiderTradeKind.award),
            ("A", InsiderTradeKind.award),
            ("G-Gift", InsiderTradeKind.other),
            ("M-Exempt", InsiderTradeKind.other),
            ("F-InKind", InsiderTradeKind.other),
            ("", InsiderTradeKind.other),
            ("   ", InsiderTradeKind.other),
        ]
    )
    func transactionCodesMapToKinds(code: String, expected: InsiderTradeKind) {
        #expect(InsiderActivity.kind(forTransactionType: code) == expected)
    }

    @Test("A missing transaction code is `other`, not a guess")
    func missingTransactionCodeIsOther() {
        #expect(InsiderActivity.kind(forTransactionType: nil) == .other)
    }

    // MARK: - Cluster buy

    @Test("Three distinct buyers inside 20 days are a cluster buy")
    func threeDistinctBuyersInTwentyDaysCluster() throws {
        let response = build([
            wire(date: "2026-06-01", name: "Ann Alpha", shares: 100, price: 10),
            wire(date: "2026-06-10", name: "Bob Beta", shares: 200, price: 10),
            wire(date: "2026-06-21", name: "Cara Gamma", shares: 300, price: 10),
        ])

        let signal = try #require(response.clusterBuy)
        #expect(signal.insiderCount == 3)
        #expect(signal.windowStart == "2026-06-01")
        #expect(signal.windowEnd == "2026-06-21")
        #expect(signal.totalValue == 6000)
    }

    @Test("Repeat buys by two people are not a cluster, however many filings")
    func repeatedBuyersAreNotACluster() {
        let response = build([
            wire(date: "2026-06-01", name: "Ann Alpha"),
            wire(date: "2026-06-05", name: "Ann Alpha"),
            wire(date: "2026-06-09", name: "Bob Beta"),
            wire(date: "2026-06-14", name: "Ann Alpha"),
            wire(date: "2026-06-18", name: "Bob Beta"),
        ])

        #expect(response.clusterBuy == nil)
    }

    @Test("Three buyers spread over 45 days are not a cluster")
    func threeBuyersOverFortyFiveDaysAreNotACluster() {
        let response = build([
            wire(date: "2026-05-05", name: "Ann Alpha"),
            wire(date: "2026-05-28", name: "Bob Beta"),
            wire(date: "2026-06-19", name: "Cara Gamma"),
        ])

        #expect(response.clusterBuy == nil)
    }

    @Test("Sells and awards never form a cluster buy")
    func onlyOpenMarketBuysCount() {
        let response = build([
            wire(date: "2026-06-01", name: "Ann Alpha", type: "S-Sale"),
            wire(date: "2026-06-05", name: "Bob Beta", type: "A-Award"),
            wire(date: "2026-06-09", name: "Cara Gamma", type: "G-Gift"),
            wire(date: "2026-06-12", name: "Dan Delta", type: "P-Purchase"),
        ])

        #expect(response.clusterBuy == nil)
    }

    @Test("The most recent qualifying window wins when two clusters exist")
    func theMostRecentClusterWins() throws {
        let response = build([
            // Older cluster.
            wire(date: "2025-09-01", name: "Ann Alpha"),
            wire(date: "2025-09-04", name: "Bob Beta"),
            wire(date: "2025-09-08", name: "Cara Gamma"),
            // Newer cluster.
            wire(date: "2026-06-02", name: "Dan Delta"),
            wire(date: "2026-06-06", name: "Eve Epsilon"),
            wire(date: "2026-06-11", name: "Fay Zeta"),
        ])

        let signal = try #require(response.clusterBuy)
        #expect(signal.windowStart == "2026-06-02")
        #expect(signal.windowEnd == "2026-06-11")
    }

    @Test("Buyers whose price is unknown still count, and contribute nothing to the total")
    func unknownPricesContributeZeroValue() throws {
        let response = build([
            wire(date: "2026-06-01", name: "Ann Alpha", shares: 100, price: 10),
            wire(date: "2026-06-05", name: "Bob Beta", shares: 200, price: nil),
            wire(date: "2026-06-09", name: "Cara Gamma", shares: 300, price: nil),
        ])

        let signal = try #require(response.clusterBuy)
        #expect(signal.insiderCount == 3)
        #expect(signal.totalValue == 1000)
    }

    // MARK: - Summary

    @Test("The summary nets buys against sells and ignores awards")
    func summaryNetsBuysAgainstSells() {
        let response = build([
            wire(date: "2026-06-01", name: "Ann Alpha", type: "P-Purchase", shares: 1000, price: 10),
            wire(date: "2026-06-02", name: "Bob Beta", type: "P-Purchase", shares: 500, price: 20),
            wire(date: "2026-06-03", name: "Cara Gamma", type: "S-Sale", shares: 400, price: 25),
            wire(date: "2026-06-04", name: "Dan Delta", type: "A-Award", shares: 9000, price: 30),
        ])

        #expect(response.summary.buys == 2)
        #expect(response.summary.sells == 1)
        // 1000 + 500 - 400
        #expect(response.summary.netShares == 1100)
        // 10_000 + 10_000 - 10_000
        #expect(response.summary.netValue == 10000)
    }

    @Test("An empty upstream answer is an empty response, not an error")
    func emptyUpstreamIsAnEmptyResponse() {
        let response = build([])

        #expect(response.symbol == "AAPL")
        #expect(response.windowDays == 365)
        #expect(response.trades.isEmpty)
        #expect(response.summary == InsiderActivitySummary(buys: 0, sells: 0, netShares: 0, netValue: 0))
        #expect(response.clusterBuy == nil)
    }

    // MARK: - Window and shape

    @Test("Trades older than the window are dropped")
    func tradesOlderThanTheWindowAreDropped() {
        let response = build(
            [
                wire(date: "2026-06-20", name: "Ann Alpha"),
                wire(date: "2026-03-01", name: "Bob Beta"),
                wire(date: "2026-01-15", name: "Cara Gamma"),
            ],
            windowDays: 30
        )

        #expect(response.windowDays == 30)
        #expect(response.trades.map(\.date) == ["2026-06-20"])
    }

    @Test("Trades come back newest first")
    func tradesComeBackNewestFirst() {
        let response = build([
            wire(date: "2026-02-10", name: "Ann Alpha"),
            wire(date: "2026-06-20", name: "Bob Beta"),
            wire(date: "2026-04-01", name: "Cara Gamma"),
        ])

        #expect(response.trades.map(\.date) == ["2026-06-20", "2026-04-01", "2026-02-10"])
    }

    @Test("A trade carries the raw code alongside the derived kind, and a computed value")
    func tradeCarriesRawCodeAndComputedValue() throws {
        let response = build([
            wire(date: "2026-06-20", name: "Ann Alpha", type: "P-Purchase", shares: 250, price: 4),
        ])

        let trade = try #require(response.trades.first)
        #expect(trade.reporterName == "Ann Alpha")
        #expect(trade.reporterTitle == "Chief Executive Officer")
        #expect(trade.transactionType == "P-Purchase")
        #expect(trade.kind == .buy)
        #expect(trade.shares == 250)
        #expect(trade.pricePerShare == 4)
        #expect(trade.value == 1000)
        #expect(trade.sharesOwnedAfter == 5000)
        #expect(trade.filingURL == "https://sec.gov/filing")
    }

    @Test("A row with no usable transaction date is skipped rather than dated today")
    func rowsWithoutADateAreSkipped() {
        let undated = FMPInsiderTrade(
            symbol: "AAPL",
            filingDate: nil,
            transactionDate: nil,
            transactionType: "P-Purchase",
            securitiesTransacted: 100,
            securitiesOwned: nil,
            price: nil,
            reportingName: "Ann Alpha",
            typeOfOwner: nil,
            acquisitionOrDisposition: nil,
            url: nil
        )

        #expect(build([undated]).trades.isEmpty)
    }

    // MARK: - Request window

    @Test(
        "The requested day window is clamped to 30…1825",
        arguments: [(0, 30), (29, 30), (30, 30), (365, 365), (1825, 1825), (5000, 1825)]
    )
    func windowDaysAreClamped(requested: Int, expected: Int) {
        #expect(InsiderActivityConfig.clampWindowDays(requested) == expected)
    }

    @Test("The cache key names the symbol and the window")
    func cacheKeyNamesSymbolAndWindow() {
        #expect(InsiderActivityConfig.redisKey(symbol: "AAPL", windowDays: 365) == "market:insider:AAPL:365")
    }
}
