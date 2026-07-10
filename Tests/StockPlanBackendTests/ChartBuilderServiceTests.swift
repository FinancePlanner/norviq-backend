import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

// MARK: - Fixtures (built via Codable to avoid 40-field memberwise inits)

private func decodeDTO<T: Decodable>(_: T.Type, fields: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: fields)
    return try JSONDecoder().decode(T.self, from: data)
}

private func baseFields(
    symbol: String,
    date: String,
    fiscalYear: String,
    period: String
) -> [String: Any] {
    [
        "symbol": symbol,
        "date": date,
        "reportedCurrency": "USD",
        "fiscalYear": fiscalYear,
        "period": period,
    ]
}

private func makeIncome(
    symbol: String = "AAPL",
    date: String,
    fiscalYear: String,
    period: String = "FY",
    revenue: Double? = nil,
    grossProfit: Double? = nil,
    netIncome: Double? = nil
) throws -> IncomeStatementResponse {
    var fields = baseFields(symbol: symbol, date: date, fiscalYear: fiscalYear, period: period)
    if let revenue {
        fields["revenue"] = revenue
    }
    if let grossProfit {
        fields["grossProfit"] = grossProfit
    }
    if let netIncome {
        fields["netIncome"] = netIncome
    }
    return try decodeDTO(IncomeStatementResponse.self, fields: fields)
}

private func makeCashFlow(
    symbol: String = "AAPL",
    date: String,
    fiscalYear: String,
    period: String = "FY",
    freeCashFlow: Double? = nil
) throws -> CashFlowStatementResponse {
    var fields = baseFields(symbol: symbol, date: date, fiscalYear: fiscalYear, period: period)
    if let freeCashFlow {
        fields["freeCashFlow"] = freeCashFlow
    }
    return try decodeDTO(CashFlowStatementResponse.self, fields: fields)
}

private func makeBalance(
    symbol: String = "AAPL",
    date: String,
    fiscalYear: String,
    period: String = "FY",
    totalAssets: Double? = nil
) throws -> BalanceSheetStatementResponse {
    var fields = baseFields(symbol: symbol, date: date, fiscalYear: fiscalYear, period: period)
    if let totalAssets {
        fields["totalAssets"] = totalAssets
    }
    return try decodeDTO(BalanceSheetStatementResponse.self, fields: fields)
}

// MARK: - Request parsing

struct ChartBuilderRequestParsingTests {
    @Test func parsesValidRequest() throws {
        let request = try DefaultChartBuilderService.parseRequest(
            symbol: "aapl",
            metricsQuery: "revenue, freeCashFlow",
            periodQuery: "quarter",
            limitQuery: 8,
            compareQuery: "msft,AAPL"
        )
        #expect(request.symbol == "AAPL")
        #expect(request.metricKeys == ["revenue", "freeCashFlow"])
        #expect(request.period == .quarter)
        #expect(request.limit == 8)
        #expect(request.compare == ["MSFT"], "primary symbol must be dropped from compare")
    }

    @Test func rejectsUnknownMetrics() {
        #expect(throws: Abort.self) {
            try DefaultChartBuilderService.parseRequest(
                symbol: "AAPL",
                metricsQuery: "revenue,notAMetric",
                periodQuery: nil,
                limitQuery: nil,
                compareQuery: nil
            )
        }
    }

    @Test func rejectsEmptyMetrics() {
        #expect(throws: Abort.self) {
            try DefaultChartBuilderService.parseRequest(
                symbol: "AAPL", metricsQuery: nil, periodQuery: nil, limitQuery: nil, compareQuery: nil
            )
        }
    }

    @Test func rejectsTTMForUnsupportedMetric() {
        #expect(throws: Abort.self) {
            try DefaultChartBuilderService.parseRequest(
                symbol: "AAPL",
                metricsQuery: "revenueGrowth",
                periodQuery: "ttm",
                limitQuery: nil,
                compareQuery: nil
            )
        }
    }

    @Test func allowsTTMForFlowAndMarginMetrics() throws {
        let request = try DefaultChartBuilderService.parseRequest(
            symbol: "AAPL",
            metricsQuery: "revenue,netProfitMargin,totalAssets,fcfMargin",
            periodQuery: "ttm",
            limitQuery: nil,
            compareQuery: nil
        )
        #expect(request.period == .ttm)
        #expect(request.limit == 20)
    }

    @Test func rejectsTooManyCompareSymbols() {
        #expect(throws: Abort.self) {
            try DefaultChartBuilderService.parseRequest(
                symbol: "AAPL",
                metricsQuery: "revenue",
                periodQuery: nil,
                limitQuery: nil,
                compareQuery: "MSFT,GOOG,AMZN,META"
            )
        }
    }

    @Test func clampsLimit() throws {
        let request = try DefaultChartBuilderService.parseRequest(
            symbol: "AAPL", metricsQuery: "revenue", periodQuery: nil, limitQuery: 999, compareQuery: nil
        )
        #expect(request.limit == DefaultChartBuilderService.maxLimit)
    }
}

// MARK: - TTM math

struct ChartBuilderTTMTests {
    @Test func rollingSumsRequireFourConsecutiveQuarters() {
        let dates = ["2023-12-30", "2024-03-30", "2024-06-29", "2024-09-28", "2024-12-28"]
        let values: [Double?] = [10, 20, 30, 40, 50]
        let sums = DefaultChartBuilderService.rollingFourQuarterSums(values: values, dates: dates)
        #expect(sums == [nil, nil, nil, 100, 140])
    }

    @Test func rollingSumsNilWhenValueMissing() {
        let dates = ["2023-12-30", "2024-03-30", "2024-06-29", "2024-09-28"]
        let values: [Double?] = [10, nil, 30, 40]
        let sums = DefaultChartBuilderService.rollingFourQuarterSums(values: values, dates: dates)
        #expect(sums == [nil, nil, nil, nil])
    }

    @Test func rollingSumsNilAcrossReportingGap() {
        // Q2 2023 → Q4 2024 window spans far beyond 4 consecutive quarters.
        let dates = ["2023-06-30", "2024-03-30", "2024-06-29", "2024-09-28"]
        let values: [Double?] = [10, 20, 30, 40]
        let sums = DefaultChartBuilderService.rollingFourQuarterSums(values: values, dates: dates)
        #expect(sums == [nil, nil, nil, nil])
    }
}

// MARK: - Growth stats

struct ChartBuilderGrowthStatsTests {
    private func annualPeriods(years: ClosedRange<Int>) -> [ChartBuilderPeriod] {
        years.map {
            ChartBuilderPeriod(label: "FY\($0)", fiscalYear: "\($0)", fiscalPeriod: "FY", endDate: "\($0)-09-28")
        }
    }

    @Test func computesYoyTotalAndCagr() throws {
        let periods = annualPeriods(years: 2020 ... 2024)
        let values: [Double?] = [100, 110, 121, 133.1, 146.41]
        let stats = try #require(
            DefaultChartBuilderService.growthStats(values: values, periods: periods, kind: .annual)
        )
        #expect(stats.yoy.count == 4)
        let firstYoy = try #require(stats.yoy.first)
        #expect(firstYoy.absolute == 10)
        #expect(abs((firstYoy.percent ?? 0) - 0.1) < 0.0001)
        #expect(abs((stats.totalChange ?? 0) - 46.41) < 0.0001)
        #expect(abs((stats.totalChangePercent ?? 0) - 0.4641) < 0.0001)
        #expect(abs((stats.cagr ?? 0) - 0.1) < 0.001)
    }

    @Test func negativeBaseYieldsNilPercentStats() throws {
        let periods = annualPeriods(years: 2021 ... 2024)
        let values: [Double?] = [-50, 10, 20, 30]
        let stats = try #require(
            DefaultChartBuilderService.growthStats(values: values, periods: periods, kind: .annual)
        )
        #expect(stats.totalChange == 80)
        #expect(stats.totalChangePercent == nil)
        #expect(stats.cagr == nil)
        let firstYoy = try #require(stats.yoy.first)
        #expect(firstYoy.percent == nil)
    }

    @Test func quarterlyYoyUsesFourPeriodLag() throws {
        let periods = (0 ..< 8).map { index -> ChartBuilderPeriod in
            let year = 2023 + index / 4
            let quarter = index % 4 + 1
            return ChartBuilderPeriod(
                label: "Q\(quarter) \(year)",
                fiscalYear: "\(year)",
                fiscalPeriod: "Q\(quarter)",
                endDate: String(format: "%d-%02d-28", year, quarter * 3)
            )
        }
        let values: [Double?] = [10, 20, 30, 40, 15, 25, 35, 45]
        let stats = try #require(
            DefaultChartBuilderService.growthStats(values: values, periods: periods, kind: .quarter)
        )
        #expect(stats.yoy.count == 4)
        #expect(stats.yoy.first?.absolute == 5)
    }
}

// MARK: - Assembly

struct ChartBuilderAssemblyTests {
    private func annualRequest(
        metrics: [String],
        compare: [String] = [],
        limit: Int = 10,
        period: ChartBuilderPeriodKind = .annual
    ) -> ChartBuilderRequest {
        ChartBuilderRequest(symbol: "AAPL", metricKeys: metrics, period: period, limit: limit, compare: compare)
    }

    @Test func assemblesAlignedAnnualSeries() throws {
        var bundle = ChartBuilderStatementBundle()
        bundle.income = try [
            makeIncome(date: "2022-09-24", fiscalYear: "2022", revenue: 394_000_000_000),
            makeIncome(date: "2023-09-30", fiscalYear: "2023", revenue: 383_000_000_000),
            makeIncome(date: "2024-09-28", fiscalYear: "2024", revenue: 391_000_000_000),
        ]
        bundle.cashFlow = try [
            makeCashFlow(date: "2022-09-24", fiscalYear: "2022", freeCashFlow: 111_000_000_000),
            makeCashFlow(date: "2023-09-30", fiscalYear: "2023", freeCashFlow: 99_000_000_000),
            makeCashFlow(date: "2024-09-28", fiscalYear: "2024", freeCashFlow: 108_000_000_000),
        ]

        let response = DefaultChartBuilderService.assemble(
            request: annualRequest(metrics: ["revenue", "freeCashFlow"]),
            bundles: ["AAPL": bundle],
            companies: ["AAPL": ChartBuilderCompany(symbol: "AAPL", name: "Apple Inc.", currency: "USD")]
        )

        #expect(response.periods.map(\.label) == ["FY2022", "FY2023", "FY2024"])
        #expect(response.series.count == 2)
        let revenue = try #require(response.series.first { $0.metricKey == "revenue" })
        #expect(revenue.values == [394_000_000_000, 383_000_000_000, 391_000_000_000])
        #expect(revenue.currency == "USD")
        #expect(revenue.growth != nil)
    }

    @Test func alignsOffsetFiscalYearPeerBySharedFiscalYear() throws {
        var primary = ChartBuilderStatementBundle()
        primary.income = try [
            makeIncome(date: "2023-09-30", fiscalYear: "2023", revenue: 383),
            makeIncome(date: "2024-09-28", fiscalYear: "2024", revenue: 391),
        ]
        var peer = ChartBuilderStatementBundle()
        // MSFT-style June fiscal year end; FY2023 present, FY2024 missing.
        peer.income = try [
            makeIncome(symbol: "MSFT", date: "2023-06-30", fiscalYear: "2023", revenue: 211),
        ]

        let response = DefaultChartBuilderService.assemble(
            request: annualRequest(metrics: ["revenue"], compare: ["MSFT"]),
            bundles: ["AAPL": primary, "MSFT": peer],
            companies: [
                "AAPL": ChartBuilderCompany(symbol: "AAPL", name: "Apple Inc.", currency: "USD"),
                "MSFT": ChartBuilderCompany(symbol: "MSFT", name: "Microsoft", currency: "USD"),
            ]
        )

        let peerSeries = try #require(response.series.first { $0.symbol == "MSFT" })
        #expect(peerSeries.values == [211, nil], "peer aligns by fiscal year; missing year is nil")
    }

    @Test func ttmAssemblyDropsWarmupAndSumsFlows() throws {
        var bundle = ChartBuilderStatementBundle()
        let quarters: [(String, String, String, Double, Double)] = [
            ("2023-07-01", "2023", "Q3", 100, 20),
            ("2023-09-30", "2023", "Q4", 110, 22),
            ("2023-12-30", "2024", "Q1", 120, 24),
            ("2024-03-30", "2024", "Q2", 130, 26),
            ("2024-06-29", "2024", "Q3", 140, 28),
        ]
        bundle.income = try quarters.map {
            try makeIncome(date: $0.0, fiscalYear: $0.1, period: $0.2, revenue: $0.3, grossProfit: $0.4)
        }
        bundle.balance = try quarters.map {
            try makeBalance(date: $0.0, fiscalYear: $0.1, period: $0.2, totalAssets: $0.3 * 10)
        }

        let response = DefaultChartBuilderService.assemble(
            request: annualRequest(metrics: ["revenue", "totalAssets", "grossProfitMargin"], limit: 2, period: .ttm),
            bundles: ["AAPL": bundle],
            companies: ["AAPL": ChartBuilderCompany(symbol: "AAPL", name: "Apple Inc.", currency: "USD")]
        )

        #expect(response.periods.map(\.label) == ["TTM Q2 2024", "TTM Q3 2024"])

        let revenue = try #require(response.series.first { $0.metricKey == "revenue" })
        #expect(revenue.values == [460, 500], "rolling 4-quarter sums")

        let assets = try #require(response.series.first { $0.metricKey == "totalAssets" })
        #expect(assets.values == [1300, 1400], "point-in-time uses latest quarter value")

        let margin = try #require(response.series.first { $0.metricKey == "grossProfitMargin" })
        let expectedMargin = 0.2
        for value in margin.values {
            #expect(abs((value ?? 0) - expectedMargin) < 0.0001, "margin recomputed from TTM components")
        }
    }
}

// MARK: - CSV

struct ChartBuilderCSVTests {
    private func makeResponse(comparing: Bool) -> ChartBuilderResponse {
        var series = [
            ChartBuilderSeries(
                symbol: "AAPL",
                metricKey: "revenue",
                label: "Revenue",
                format: .currency,
                currency: "USD",
                values: [394_000_000_000, nil],
                growth: nil
            ),
            ChartBuilderSeries(
                symbol: "AAPL",
                metricKey: "netProfitMargin",
                label: "Net Profit Margin",
                format: .percent,
                currency: nil,
                values: [0.2531, 0.24],
                growth: nil
            ),
        ]
        if comparing {
            series.append(
                ChartBuilderSeries(
                    symbol: "MSFT",
                    metricKey: "revenue",
                    label: "Revenue",
                    format: .currency,
                    currency: "USD",
                    values: [211_000_000_000, 245_000_000_000],
                    growth: nil
                )
            )
        }
        return ChartBuilderResponse(
            period: .annual,
            periods: [
                ChartBuilderPeriod(label: "FY2022", fiscalYear: "2022", fiscalPeriod: "FY", endDate: "2022-09-24"),
                ChartBuilderPeriod(label: "FY2023", fiscalYear: "2023", fiscalPeriod: "FY", endDate: "2023-09-30"),
            ],
            series: series,
            companies: []
        )
    }

    @Test func csvHasBOMHeaderAndEmptyCellsForNil() throws {
        let data = DefaultChartBuilderService.makeCSV(response: makeResponse(comparing: false))
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])

        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "Period,Fiscal Year,Revenue,Net Profit Margin (%)")
        #expect(lines[1] == "FY2022,2022,394000000000,0.2531")
        #expect(lines[2] == "FY2023,2023,,0.24", "nil value renders as empty cell")
    }

    @Test func csvPrefixesSymbolsWhenComparing() throws {
        let data = DefaultChartBuilderService.makeCSV(response: makeResponse(comparing: true))
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        let header = try #require(text.split(separator: "\n").first)
        #expect(header == "Period,Fiscal Year,AAPL Revenue,AAPL Net Profit Margin (%),MSFT Revenue")
    }

    @Test func csvFilenameIncludesSymbolAndPeriod() {
        #expect(
            DefaultChartBuilderService.csvFilename(symbol: "aapl", period: .ttm)
                == "AAPL-chart-builder-ttm.csv"
        )
    }
}
