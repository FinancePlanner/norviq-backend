import Fluent
import Foundation
import StockPlanShared
import Vapor

enum PositionMemoEvidence {
    static func build(ask: PositionMemoAsk, userId: UUID, on req: Request) async -> (pack: PositionMemoPack, mark: PositionMemoMark) {
        let market = req.application.marketDataService
        var unavailable: [String] = []

        let listings = await listings(for: ask, market: market, unavailable: &unavailable, on: req)
        let primary = choosePrimary(ask: ask, listings: listings)
        let askedQuote = await quote(symbol: ask.askedSymbol, market: market, unavailable: &unavailable, on: req)
        let primaryQuote = primary == ask.askedSymbol
            ? askedQuote
            : await quote(symbol: primary, market: market, unavailable: &unavailable, on: req)

        let liveQuote = askedQuote ?? primaryQuote
        let fx = await fxRate(live: liveQuote, costCurrency: ask.costCurrency, market: market, unavailable: &unavailable, on: req)
        let holding = await holding(userId: userId, symbols: [ask.askedSymbol, primary], on: req)

        let profile = await section("profile", unavailable: &unavailable, on: req) {
            try await market.profile(symbol: primary, on: req)
        }
        let income = await section("income-statement", unavailable: &unavailable, on: req) {
            try await market.incomeStatement(symbol: primary, limit: 6, period: "FY", on: req)
        } ?? []
        let balance = await section("balance-sheet", unavailable: &unavailable, on: req) {
            try await market.balanceSheetStatement(symbol: primary, limit: 1, period: "FY", on: req)
        }?.first
        let cashFlow = await section("cash-flow", unavailable: &unavailable, on: req) {
            try await market.cashFlowStatement(symbol: primary, limit: 1, period: "FY", on: req)
        }?.first
        let ratios = await section("ratios", unavailable: &unavailable, on: req) {
            try await market.ratiosTTM(symbol: primary, on: req)
        }?.first
        let growth = await section("growth", unavailable: &unavailable, on: req) {
            try await market.financialGrowth(symbol: primary, limit: 1, period: "FY", on: req)
        }?.first
        let estimates = await section("analyst-estimates", unavailable: &unavailable, on: req) {
            try await market.analystEstimates(symbol: primary, period: "annual", page: nil, limit: 3, on: req)
        } ?? []
        let grades = await section("grades", unavailable: &unavailable, on: req) {
            try await market.gradesConsensus(symbol: primary, on: req)
        }?.first
        let basic = await section("basic-financials", unavailable: &unavailable, on: req) {
            try await market.basicFinancials(symbol: primary, on: req)
        }
        let insider = await section("insider", unavailable: &unavailable, on: req) {
            try await market.insiderActivity(symbol: primary, windowDays: 180, on: req)
        }
        let news = await section("news", unavailable: &unavailable, on: req) {
            try await req.application.marketNewsArchiveService.news(symbol: primary, limit: 8, on: req)
        } ?? []
        let earnings = await section("earnings", unavailable: &unavailable, on: req) {
            try await market.earnings(symbol: primary, limit: 6, on: req)
        } ?? []
        let technicals = await technicals(symbol: primary, market: market, unavailable: &unavailable, on: req)
        let notes = await notes(userId: userId, symbols: [ask.askedSymbol, primary], on: req)
        let targets = await targets(userId: userId, symbols: [ask.askedSymbol, primary], on: req)

        let pack = PositionMemoPack(
            askedSymbol: ask.askedSymbol,
            primarySymbol: primary,
            listings: listings,
            quotes: [askedQuote, primaryQuote].compactMap(\.self).uniquedBySymbol(),
            fx: fx,
            profile: profile.map(mapProfile),
            income: income.map(mapIncome),
            balance: balance.map(mapBalance),
            cashFlow: cashFlow.map(mapCashFlow),
            ratios: ratios.map(mapRatios),
            growth: growth.map(mapGrowth),
            estimates: estimates.map(mapEstimate),
            grades: grades.map(mapGrades),
            technicals: technicals,
            insider: insider.map(mapInsider),
            news: news.prefix(8).map(mapHeadline),
            nextEarningsDate: nextEarnings(earnings),
            holding: holding,
            notes: notes,
            targets: targets,
            basicMetrics: mapBasic(basic),
            unavailable: unavailable
        )

        let mark = PositionMemoMath.mark(PositionMemoMath.Input(
            askedSymbol: ask.askedSymbol,
            primarySymbol: primary,
            statedCost: ask.cost,
            statedCurrency: ask.costCurrency,
            statedPercent: ask.statedPercent,
            live: liveQuote.map { PositionMemoMath.QuoteInput(symbol: $0.symbol, price: $0.price, currency: $0.currency) },
            primary: primaryQuote.map { PositionMemoMath.QuoteInput(symbol: $0.symbol, price: $0.price, currency: $0.currency) },
            fxRate: fx?.rate,
            fxPair: fx?.pair,
            fxDate: fx?.date,
            shares: holding?.shares,
            lotAveragePrice: holding?.averageBuyPrice
        ))
        return (pack, mark)
    }

    private static func listings(
        for ask: PositionMemoAsk,
        market: any MarketDataService,
        unavailable: inout [String],
        on req: Request
    ) async -> [PositionMemoPack.Listing] {
        var queries = [ask.askedSymbol]
        if let companion = ask.companionSymbol {
            queries.append(companion)
        }
        var rows: [PositionMemoPack.Listing] = []
        for query in queries {
            do {
                let hits = try await market.search(query: query, on: req)
                rows.append(contentsOf: hits.prefix(4).map {
                    PositionMemoPack.Listing(symbol: $0.symbol.uppercased(), name: $0.name, exchange: $0.exchange, currency: $0.currency)
                })
            } catch {
                unavailable.append("search")
                req.logger.warning("position_memo.section_failed section=search error=\(error)")
            }
        }
        return rows
    }

    private static func choosePrimary(ask: PositionMemoAsk, listings: [PositionMemoPack.Listing]) -> String {
        if let companion = ask.companionSymbol {
            return companion
        }
        let us = listings.first { listing in
            !listing.symbol.contains(".") && isUSExchange(listing.exchange)
        }
        if let us, us.symbol != ask.askedSymbol {
            return us.symbol
        }
        return ask.askedSymbol
    }

    private static func isUSExchange(_ exchange: String) -> Bool {
        let folded = exchange.uppercased()
        return ["NASDAQ", "NYSE", "NMS", "NYQ", "XNAS", "XNYS", "AMEX", "ARCA", "NGS"].contains { folded.contains($0) }
    }

    private static func quote(
        symbol: String,
        market: any MarketDataService,
        unavailable: inout [String],
        on req: Request
    ) async -> PositionMemoPack.Quote? {
        do {
            let quote = try await market.quote(symbol: symbol, on: req)
            let volume = await latestVolume(symbol: symbol, market: market, on: req)
            let asOf = Date(timeIntervalSince1970: quote.timestamp)
            return PositionMemoPack.Quote(
                symbol: quote.symbol,
                currency: quote.currency,
                price: quote.currentPrice,
                previousClose: quote.previousClose,
                change: quote.change,
                percentChange: quote.percentChange,
                high: quote.high,
                low: quote.low,
                volume: volume,
                asOf: Self.internetDate(asOf)
            )
        } catch {
            unavailable.append("quote:\(symbol)")
            req.logger.warning("position_memo.section_failed section=quote symbol=\(symbol) error=\(error)")
            return nil
        }
    }

    private static func latestVolume(symbol: String, market: any MarketDataService, on req: Request) async -> Int? {
        guard let history = try? await market.history(symbol: symbol, from: TechnicalSignalsConfig.historyStart(), to: nil, on: req) else {
            return nil
        }
        return history.bars.last?.volume
    }

    private static func fxRate(
        live: PositionMemoPack.Quote?,
        costCurrency: String?,
        market: any MarketDataService,
        unavailable: inout [String],
        on req: Request
    ) async -> PositionMemoPack.FX? {
        guard let live, let costCurrency, live.currency.caseInsensitiveCompare(costCurrency) != .orderedSame else { return nil }
        let direct = PositionMemoMath.fxPair(from: live.currency, to: costCurrency)
        if let rate = try? await market.fx(pair: direct, on: req), rate.rate > 0 {
            return PositionMemoPack.FX(pair: direct, rate: rate.rate, date: rate.date)
        }
        let inverse = PositionMemoMath.fxPair(from: costCurrency, to: live.currency)
        if let rate = try? await market.fx(pair: inverse, on: req), rate.rate > 0 {
            return PositionMemoPack.FX(pair: direct, rate: 1 / rate.rate, date: rate.date)
        }
        unavailable.append("fx")
        req.logger.warning("position_memo.section_failed section=fx pair=\(direct)")
        return nil
    }

    private static func technicals(
        symbol: String,
        market: any MarketDataService,
        unavailable: inout [String],
        on req: Request
    ) async -> PositionMemoPack.Technicals? {
        do {
            let history = try await market.history(symbol: symbol, from: TechnicalSignalsConfig.historyStart(), to: nil, on: req)
            guard let signals = TechnicalSignals.compute(symbol: symbol, bars: history.bars) else { return nil }
            return PositionMemoPack.Technicals(
                asOf: signals.asOf,
                close: signals.close,
                sma50: signals.sma50,
                sma200: signals.sma200,
                trend: signals.trend.rawValue,
                fiftyTwoWeekHigh: signals.fiftyTwoWeek.high,
                fiftyTwoWeekLow: signals.fiftyTwoWeek.low
            )
        } catch {
            unavailable.append("technicals")
            req.logger.warning("position_memo.section_failed section=technicals error=\(error)")
            return nil
        }
    }

    private static func section<T>(
        _ name: String,
        unavailable: inout [String],
        on req: Request,
        _ work: () async throws -> T
    ) async -> T? {
        do {
            return try await work()
        } catch {
            unavailable.append(name)
            req.logger.warning("position_memo.section_failed section=\(name) error=\(error)")
            return nil
        }
    }

    private static func holding(userId: UUID, symbols: [String], on req: Request) async -> PositionMemoPack.Holding? {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard let stocks = try? await Stock.query(on: req.db).filter(\.$userId == userId).all() else { return nil }
        let lots = stocks.filter { wanted.contains($0.symbol.uppercased()) && $0.shares > 0 }
        guard !lots.isEmpty else { return nil }
        let shares = lots.reduce(0.0) { $0 + $1.shares }
        guard shares > 0 else { return nil }
        let cost = lots.reduce(0.0) { $0 + $1.shares * $1.buyPrice } / shares
        let symbol = lots.first { $0.symbol.uppercased() == symbols[0].uppercased() }?.symbol ?? lots[0].symbol
        return PositionMemoPack.Holding(symbol: symbol.uppercased(), shares: shares, averageBuyPrice: cost, lotCount: lots.count)
    }

    private static func notes(userId: UUID, symbols: [String], on req: Request) async -> [PositionMemoPack.Note] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard let rows = try? await ResearchNote.query(on: req.db).filter(\.$userId == userId).all() else { return [] }
        return rows.filter { wanted.contains($0.symbol.uppercased()) }.prefix(4).map { note in
            PositionMemoPack.Note(
                symbol: note.symbol.uppercased(),
                title: note.title,
                thesis: String(note.thesis.prefix(400))
            )
        }
    }

    private static func targets(userId: UUID, symbols: [String], on req: Request) async -> [PositionMemoPack.TargetLine] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard let rows = try? await Target.query(on: req.db).filter(\.$userId == userId).all() else { return [] }
        return rows.filter { wanted.contains($0.symbol.uppercased()) }.prefix(6).map { target in
            PositionMemoPack.TargetLine(
                symbol: target.symbol.uppercased(),
                scenario: target.scenario,
                targetPrice: target.targetPrice,
                targetDate: target.targetDate.map(Self.dayString)
            )
        }
    }

    private static func mapProfile(_ profile: CompanyProfileResponse) -> PositionMemoPack.Profile {
        PositionMemoPack.Profile(
            name: profile.name,
            country: profile.country,
            exchange: profile.exchange,
            currency: profile.currency,
            industry: profile.finnhubIndustry,
            ipo: profile.ipo,
            shareOutstandingMillions: profile.shareOutstanding,
            marketCapitalization: profile.marketCapitalization,
            weburl: profile.weburl
        )
    }

    private static func mapIncome(_ row: IncomeStatementResponse) -> PositionMemoPack.IncomeYear {
        PositionMemoPack.IncomeYear(
            date: row.date,
            fiscalYear: row.fiscalYear,
            revenue: row.revenue,
            operatingIncome: row.operatingIncome,
            netIncome: row.netIncome,
            interestIncome: row.interestIncome,
            epsDiluted: row.epsDiluted
        )
    }

    private static func mapBalance(_ row: BalanceSheetStatementResponse) -> PositionMemoPack.Balance {
        PositionMemoPack.Balance(
            date: row.date,
            cashAndEquivalents: row.cashAndCashEquivalents,
            shortTermInvestments: row.shortTermInvestments,
            totalDebt: row.totalDebt,
            totalEquity: row.totalEquity ?? row.totalStockholdersEquity
        )
    }

    private static func mapCashFlow(_ row: CashFlowStatementResponse) -> PositionMemoPack.CashFlow {
        PositionMemoPack.CashFlow(
            date: row.date,
            operatingCashFlow: row.operatingCashFlow ?? row.netCashProvidedByOperatingActivities,
            freeCashFlow: row.freeCashFlow
        )
    }

    private static func mapRatios(_ row: RatiosTTMResponse) -> PositionMemoPack.Ratios {
        PositionMemoPack.Ratios(
            operatingMargin: row.operatingProfitMarginTTM,
            netMargin: row.netProfitMarginTTM,
            priceToEarnings: row.priceToEarningsRatioTTM,
            priceToBook: row.priceToBookRatioTTM,
            priceToSales: row.priceToSalesRatioTTM,
            enterpriseValue: row.enterpriseValueTTM
        )
    }

    private static func mapGrowth(_ row: FinancialGrowthResponse) -> PositionMemoPack.Growth {
        PositionMemoPack.Growth(date: row.date, revenueGrowth: row.revenueGrowth, netIncomeGrowth: row.netIncomeGrowth)
    }

    private static func mapEstimate(_ row: AnalystEstimatesResponse) -> PositionMemoPack.Estimate {
        PositionMemoPack.Estimate(
            date: row.date,
            revenueAvg: row.revenueAvg,
            epsAvg: row.epsAvg,
            epsLow: row.epsLow,
            epsHigh: row.epsHigh,
            analystCount: row.numAnalystsEps
        )
    }

    private static func mapGrades(_ row: GradesConsensusResponse) -> PositionMemoPack.Grades {
        PositionMemoPack.Grades(
            strongBuy: row.strongBuy,
            buy: row.buy,
            hold: row.hold,
            sell: row.sell,
            strongSell: row.strongSell,
            consensus: row.consensus
        )
    }

    private static func mapInsider(_ row: InsiderActivityResponse) -> PositionMemoPack.Insider {
        PositionMemoPack.Insider(
            buys: row.summary.buys,
            sells: row.summary.sells,
            netShares: row.summary.netShares,
            netValue: row.summary.netValue,
            recent: row.trades.prefix(5).map {
                PositionMemoPack.Insider.Trade(date: $0.date, name: $0.reporterName, kind: $0.kind.rawValue, shares: $0.shares, value: $0.value)
            }
        )
    }

    private static func mapHeadline(_ row: StockNews) -> PositionMemoPack.Headline {
        PositionMemoPack.Headline(
            title: String(row.title.prefix(200)),
            url: row.url,
            date: row.date,
            source: row.source
        )
    }

    private static func mapBasic(_ response: BasicFinancialsResponse?) -> [String: Double] {
        guard let response else { return [:] }
        let wanted = ["52WeekHigh", "52WeekLow", "marketCapitalization", "peTTM", "bookValuePerShareAnnual"]
        var values: [String: Double] = [:]
        for key in wanted {
            if let number = metricNumber(key, in: response) {
                values[key] = number
            }
        }
        return values
    }

    private static func metricNumber(_ key: String, in response: BasicFinancialsResponse) -> Double? {
        guard let value = response.metric[key] else { return nil }
        if case let .number(number) = value {
            return number
        }
        return nil
    }

    private static func nextEarnings(_ rows: [EarningsResponse]) -> String? {
        let today = dayString(Date())
        return rows.map(\.date).filter { $0 >= today }.sorted().first
    }

    private static func internetDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private extension [PositionMemoPack.Quote] {
    func uniquedBySymbol() -> [PositionMemoPack.Quote] {
        var seen: Set<String> = []
        return filter { seen.insert($0.symbol.uppercased()).inserted }
    }
}
