import Fluent
import Foundation
import Vapor

enum StatisticsPeriod: String, CaseIterable, Sendable {
    case oneWeek = "1w"
    case oneMonth = "1m"
    case threeMonths = "3m"
    case sixMonths = "6m"
    case oneYear = "1y"
    case ytd = "ytd"
    case all = "all"

    var dayWindow: Int? {
        switch self {
        case .oneWeek:
            return 7
        case .oneMonth:
            return 30
        case .threeMonths:
            return 90
        case .sixMonths:
            return 180
        case .oneYear:
            return 365
        case .ytd:
            return nil
        case .all:
            return nil
        }
    }
}

struct StatisticsQueryOptions: Sendable {
    let period: StatisticsPeriod
    let top: Int
    let benchmarkSymbol: String
    let asOfDate: Date?
}

protocol StatisticsRepository: Sendable {
    func stockLevelScorecard(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func stockAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func sectorAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func calendarPerformance(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func contributionAnalysis(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func winnersVsLosers(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func volatilitySnapshot(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func currencySplit(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func scenarioTracking(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func notesQualityMetrics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func importedStocksStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func watchlistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func looklistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func marketStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
    func overviewStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel
}

struct DatabaseStatisticsRepository: StatisticsRepository {
    func stockLevelScorecard(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }

    func stockAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForAllocation(model, top: options.top)
        return model
    }

    func sectorAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForSector(model)
        return model
    }

    func calendarPerformance(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForCalendar(model)
        return model
    }

    func contributionAnalysis(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForContributions(model, top: options.top)
        return model
    }

    func winnersVsLosers(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForWinnersLosers(model, top: options.top)
        return model
    }

    func volatilitySnapshot(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForVolatility(model, top: options.top)
        return model
    }

    func currencySplit(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForCurrency(model, top: options.top)
        return model
    }

    func scenarioTracking(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForScenarioTracking(model)
        return model
    }

    func notesQualityMetrics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        var model = try await buildOverview(userId: userId, options: options, on: db)
        model = trimForNotesQuality(model)
        return model
    }

    func importedStocksStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }

    func watchlistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }

    func looklistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }

    func marketStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }

    func overviewStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        try await buildOverview(userId: userId, options: options, on: db)
    }
}

private extension DatabaseStatisticsRepository {
    struct SnapshotRow: Sendable {
        let symbol: String
        let shares: Double
        let buyPrice: Double
        let costBasis: Double
        let currentPrice: Double
        let currency: String
        let marketValue: Double
        let dailyChangePercent: Double?
        let weeklyChangePercent: Double?
        let monthlyChangePercent: Double?
        let unrealizedPnl: Double
    }

    func buildOverview(
        userId: UUID,
        options: StatisticsQueryOptions,
        on db: any Database
    ) async throws -> StatisticsViewModel {
        let generatedAt = Date()
        let asOf = startOfDay(options.asOfDate ?? generatedAt)

        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let watchlist = try await WatchlistItem.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let notes = try await ResearchNote.query(on: db)
            .filter(\.$userId == userId)
            .all()
        let targets = try await Target.query(on: db)
            .filter(\.$userId == userId)
            .all()

        let stockSymbols = uniqueSymbols(from: stocks.map(\.symbol))
        let watchlistSymbols = uniqueSymbols(from: watchlist.map(\.symbol))
        let notesSymbols = uniqueSymbols(from: notes.map(\.symbol))
        let targetsSymbols = uniqueSymbols(from: targets.map(\.symbol))

        let combinedSymbols = uniqueSymbols(from: stockSymbols + watchlistSymbols + notesSymbols + targetsSymbols + [options.benchmarkSymbol])
        let quoteBySymbol = try await loadLatestQuotes(symbols: combinedSymbols, on: db)
        let historyBySymbol = try await loadPriceHistoryBySymbol(
            symbols: combinedSymbols,
            period: options.period,
            asOf: asOf,
            on: db
        )

        let notesBySymbol = Dictionary(grouping: notes) { normalizeSymbol($0.symbol) }
        let targetsBySymbol = Dictionary(grouping: targets) { normalizeSymbol($0.symbol) }

        let snapshots = buildStockSnapshots(
            stocks: stocks,
            quoteBySymbol: quoteBySymbol,
            historyBySymbol: historyBySymbol,
            asOf: asOf
        )

        let importedStocks = buildImportedStocksStatistics(
            snapshots: snapshots,
            notesBySymbol: notesBySymbol,
            historyBySymbol: historyBySymbol,
            asOf: asOf
        )

        let watchlistStatistics = buildWatchlistStatistics(
            watchlistSymbols: watchlistSymbols,
            notesBySymbol: notesBySymbol,
            targetsBySymbol: targetsBySymbol,
            top: options.top
        )

        let looklistStatistics = buildLooklistStatistics(
            stockSymbols: Set(stockSymbols),
            watchlistSymbols: Set(watchlistSymbols),
            notesBySymbol: notesBySymbol,
            targetsBySymbol: targetsBySymbol
        )

        let marketStatistics = buildMarketStatistics(
            benchmark: options.benchmarkSymbol,
            symbols: uniqueSymbols(from: stockSymbols + watchlistSymbols),
            quoteBySymbol: quoteBySymbol,
            historyBySymbol: historyBySymbol,
            asOf: asOf,
            top: options.top
        )

        return StatisticsViewModel(
            generatedAt: generatedAt,
            importedStocks: importedStocks,
            watchlist: watchlistStatistics,
            looklist: looklistStatistics,
            market: marketStatistics
        )
    }

    func buildStockSnapshots(
        stocks: [Stock],
        quoteBySymbol: [String: QuoteCache],
        historyBySymbol: [String: [PriceHistory]],
        asOf: Date
    ) -> [SnapshotRow] {
        stocks.map { stock in
            let symbol = normalizeSymbol(stock.symbol)
            let quote = quoteBySymbol[symbol]
            let history = historyBySymbol[symbol] ?? []

            let currentPrice = quote?.price ?? history.last?.close ?? stock.buyPrice
            let currency = quote?.currency.uppercased() ?? "USD"
            let costBasis = stock.shares * stock.buyPrice
            let marketValue = stock.shares * currentPrice

            let dailyRef = referencePrice(history: history, beforeOrAt: addDays(asOf, days: -1))
            let weeklyRef = referencePrice(history: history, beforeOrAt: addDays(asOf, days: -7))
            let monthlyRef = referencePrice(history: history, beforeOrAt: addDays(asOf, days: -30))

            return SnapshotRow(
                symbol: symbol,
                shares: stock.shares,
                buyPrice: stock.buyPrice,
                costBasis: costBasis,
                currentPrice: currentPrice,
                currency: currency,
                marketValue: marketValue,
                dailyChangePercent: percentChange(current: currentPrice, reference: dailyRef),
                weeklyChangePercent: percentChange(current: currentPrice, reference: weeklyRef),
                monthlyChangePercent: percentChange(current: currentPrice, reference: monthlyRef),
                unrealizedPnl: marketValue - costBasis
            )
        }
    }

    func buildImportedStocksStatistics(
        snapshots: [SnapshotRow],
        notesBySymbol: [String: [ResearchNote]],
        historyBySymbol: [String: [PriceHistory]],
        asOf: Date
    ) -> ImportedStocksStatisticsView {
        let totalMarketValue = snapshots.reduce(0.0) { $0 + $1.marketValue }
        let totalCostBasis = snapshots.reduce(0.0) { $0 + $1.costBasis }
        let totalUnrealized = snapshots.reduce(0.0) { $0 + $1.unrealizedPnl }

        let stockSummaries = snapshots
            .sorted(by: { $0.marketValue > $1.marketValue })
            .map { row in
                StockStatisticsSummary(
                    symbol: row.symbol,
                    marketValue: round2(row.marketValue),
                    weightPercent: percentage(row.marketValue, of: totalMarketValue),
                    dailyChangePercent: row.dailyChangePercent.map(round2),
                    weeklyChangePercent: row.weeklyChangePercent.map(round2),
                    monthlyChangePercent: row.monthlyChangePercent.map(round2),
                    unrealizedPnl: round2(row.unrealizedPnl)
                )
            }

        let stockAllocations = snapshots
            .sorted(by: { $0.marketValue > $1.marketValue })
            .map { row in
                StockAllocationPoint(
                    symbol: row.symbol,
                    value: round2(row.marketValue),
                    weightPercent: percentage(row.marketValue, of: totalMarketValue)
                )
            }

        let sectorAllocations = buildSectorAllocations(
            rows: snapshots,
            notesBySymbol: notesBySymbol,
            totalMarketValue: totalMarketValue
        )

        let calendarPerformance = buildCalendarPerformance(
            rows: snapshots,
            historyBySymbol: historyBySymbol,
            asOf: asOf
        )

        return ImportedStocksStatisticsView(
            totalPositions: snapshots.count,
            totalMarketValue: round2(totalMarketValue),
            totalCostBasis: round2(totalCostBasis),
            totalUnrealizedPnl: round2(totalUnrealized),
            totalRealizedPnl: 0,
            stockSummaries: stockSummaries,
            stockAllocations: stockAllocations,
            sectorAllocations: sectorAllocations,
            calendarPerformance: calendarPerformance
        )
    }

    func buildWatchlistStatistics(
        watchlistSymbols: [String],
        notesBySymbol: [String: [ResearchNote]],
        targetsBySymbol: [String: [Target]],
        top: Int
    ) -> WatchlistStatisticsView {
        let symbolsSet = Set(watchlistSymbols)
        let symbolsWithNotes = symbolsSet.filter { symbol in
            guard let notes = notesBySymbol[symbol] else { return false }
            return !notes.isEmpty
        }.count

        let sectorCounts = Dictionary(grouping: watchlistSymbols) { symbol in
            inferSector(for: symbol, notes: notesBySymbol[symbol] ?? [])
        }.mapValues { Double($0.count) }
        let total = sectorCounts.values.reduce(0.0, +)
        let sectors = sectorCounts
            .map { sector, value in
                SectorAllocationPoint(sector: sector, value: round2(value), weightPercent: percentage(value, of: total))
            }
            .sorted(by: { $0.value > $1.value })

        let mentions = watchlistSymbols.map { symbol -> WatchlistSymbolPoint in
            let notesCount = notesBySymbol[symbol]?.count ?? 0
            let targetsCount = targetsBySymbol[symbol]?.count ?? 0
            return WatchlistSymbolPoint(symbol: symbol, mentionCount: notesCount + targetsCount)
        }
        let topWatched = Array(
            mentions
                .sorted {
                    if $0.mentionCount == $1.mentionCount {
                        return $0.symbol < $1.symbol
                    }
                    return $0.mentionCount > $1.mentionCount
                }
                .prefix(max(1, top))
        )

        return WatchlistStatisticsView(
            totalSymbols: symbolsSet.count,
            symbolsWithNotes: symbolsWithNotes,
            sectorAllocations: sectors,
            topWatched: topWatched
        )
    }

    func buildLooklistStatistics(
        stockSymbols: Set<String>,
        watchlistSymbols: Set<String>,
        notesBySymbol: [String: [ResearchNote]],
        targetsBySymbol: [String: [Target]]
    ) -> LooklistStatisticsView {
        let noteSymbols = Set(notesBySymbol.keys)
        let targetSymbols = Set(targetsBySymbol.keys)

        let candidateSymbols = watchlistSymbols.union(noteSymbols).union(targetSymbols)
        let looklistSymbols = candidateSymbols.subtracting(stockSymbols)

        let activeThreshold = addDays(Date(), days: -30)
        let activeIdeas = looklistSymbols.filter { symbol in
            let hasRecentNote = (notesBySymbol[symbol] ?? []).contains { note in
                let date = note.updatedAt ?? note.createdAt ?? .distantPast
                return date >= activeThreshold
            }
            let hasRecentTarget = (targetsBySymbol[symbol] ?? []).contains { target in
                let date = target.updatedAt ?? target.createdAt ?? .distantPast
                return date >= activeThreshold
            }
            return hasRecentNote || hasRecentTarget
        }.count

        let ideasWithTarget = looklistSymbols.filter { symbol in
            !(targetsBySymbol[symbol] ?? []).isEmpty
        }.count

        var convictionCount: [String: Int] = [:]
        for symbol in looklistSymbols {
            for target in (targetsBySymbol[symbol] ?? []) {
                let conviction = normalizeScenario(target.scenario)
                convictionCount[conviction, default: 0] += 1
            }
        }
        let convictions = convictionCount
            .map { LooklistConvictionPoint(conviction: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.conviction < $1.conviction
                }
                return $0.count > $1.count
            }

        return LooklistStatisticsView(
            totalIdeas: looklistSymbols.count,
            activeIdeas: activeIdeas,
            ideasWithTarget: ideasWithTarget,
            ideasByConviction: convictions
        )
    }

    func buildMarketStatistics(
        benchmark: String,
        symbols: [String],
        quoteBySymbol: [String: QuoteCache],
        historyBySymbol: [String: [PriceHistory]],
        asOf: Date,
        top: Int
    ) -> MarketStatisticsView {
        let benchmarkHistory = historyBySymbol[benchmark] ?? []
        let benchmarkCurrent = quoteBySymbol[benchmark]?.price ?? benchmarkHistory.last?.close

        let benchmark1D = benchmarkCurrent.flatMap { value in
            percentChange(current: value, reference: referencePrice(history: benchmarkHistory, beforeOrAt: addDays(asOf, days: -1)))
        }
        let benchmark1W = benchmarkCurrent.flatMap { value in
            percentChange(current: value, reference: referencePrice(history: benchmarkHistory, beforeOrAt: addDays(asOf, days: -7)))
        }
        let benchmark1M = benchmarkCurrent.flatMap { value in
            percentChange(current: value, reference: referencePrice(history: benchmarkHistory, beforeOrAt: addDays(asOf, days: -30)))
        }
        let benchmarkYTD = benchmarkCurrent.flatMap { value in
            percentChange(current: value, reference: referencePrice(history: benchmarkHistory, beforeOrAt: startOfYear(asOf)))
        }

        let heatmap = symbols.map { symbol -> MarketHeatmapPoint in
            let history = historyBySymbol[symbol] ?? []
            let current = quoteBySymbol[symbol]?.price ?? history.last?.close
            let previous = referencePrice(history: history, beforeOrAt: addDays(asOf, days: -1))
            let change = percentChange(current: current, reference: previous) ?? 0
            return MarketHeatmapPoint(symbol: symbol, changePercent: round2(change))
        }
        .sorted(by: { abs($0.changePercent) > abs($1.changePercent) })
        .prefix(max(1, top))

        return MarketStatisticsView(
            benchmarkSymbol: benchmark,
            benchmarkChange1D: benchmark1D.map(round2),
            benchmarkChange1W: benchmark1W.map(round2),
            benchmarkChange1M: benchmark1M.map(round2),
            benchmarkChangeYtd: benchmarkYTD.map(round2),
            heatmap: Array(heatmap)
        )
    }

    func buildSectorAllocations(
        rows: [SnapshotRow],
        notesBySymbol: [String: [ResearchNote]],
        totalMarketValue: Double
    ) -> [SectorAllocationPoint] {
        var bySector: [String: Double] = [:]
        for row in rows {
            let notes = notesBySymbol[row.symbol] ?? []
            let sector = inferSector(for: row.symbol, notes: notes)
            bySector[sector, default: 0] += row.marketValue
        }

        return bySector
            .map { sector, value in
                SectorAllocationPoint(
                    sector: sector,
                    value: round2(value),
                    weightPercent: percentage(value, of: totalMarketValue)
                )
            }
            .sorted(by: { $0.value > $1.value })
    }

    func buildCalendarPerformance(
        rows: [SnapshotRow],
        historyBySymbol: [String: [PriceHistory]],
        asOf: Date
    ) -> [CalendarPerformancePoint] {
        var portfolioByDate: [Date: Double] = [:]

        for row in rows {
            let history = historyBySymbol[row.symbol] ?? []
            for bar in history {
                let day = startOfDay(bar.date)
                portfolioByDate[day, default: 0] += row.shares * bar.close
            }
        }

        if portfolioByDate.isEmpty {
            let fallback = rows.reduce(0.0) { $0 + $1.marketValue }
            portfolioByDate[startOfDay(asOf)] = fallback
        }

        let sortedDays = portfolioByDate.keys.sorted()
        var result: [CalendarPerformancePoint] = []
        var previous: Double?

        for day in sortedDays {
            let value = portfolioByDate[day] ?? 0
            let pnl = (previous == nil) ? 0 : (value - (previous ?? 0))
            let pnlPercent = (previous == nil || (previous ?? 0) == 0) ? 0 : (pnl / (previous ?? 1)) * 100
            result.append(
                CalendarPerformancePoint(
                    date: day,
                    pnl: round2(pnl),
                    pnlPercent: round2(pnlPercent),
                    isUpDay: pnl >= 0
                )
            )
            previous = value
        }

        if result.count > 180 {
            return Array(result.suffix(180))
        }
        return result
    }

    func loadLatestQuotes(symbols: [String], on db: any Database) async throws -> [String: QuoteCache] {
        guard !symbols.isEmpty else { return [:] }
        let query = QuoteCache.query(on: db).sort(\.$asOf, .descending)
        query.group(.or) { group in
            for symbol in symbols {
                group.filter(\.$symbol == symbol)
            }
        }

        let quotes = try await query.all()
        var result: [String: QuoteCache] = [:]
        for row in quotes {
            let symbol = normalizeSymbol(row.symbol)
            if result[symbol] == nil {
                result[symbol] = row
            }
        }
        return result
    }

    func loadPriceHistoryBySymbol(
        symbols: [String],
        period: StatisticsPeriod,
        asOf: Date,
        on db: any Database
    ) async throws -> [String: [PriceHistory]] {
        guard !symbols.isEmpty else { return [:] }

        let query = PriceHistory.query(on: db).sort(\.$date, .ascending)
        query.group(.or) { group in
            for symbol in symbols {
                group.filter(\.$symbol == symbol)
            }
        }

        if let fromDate = defaultFromDate(period: period, asOf: asOf) {
            query.filter(\.$date >= fromDate)
        }
        query.filter(\.$date <= asOf)

        let history = try await query.all()
        var bySymbol: [String: [PriceHistory]] = [:]
        for bar in history {
            let symbol = normalizeSymbol(bar.symbol)
            bySymbol[symbol, default: []].append(bar)
        }
        return bySymbol
    }

    func trimForAllocation(_ model: StatisticsViewModel, top: Int) -> StatisticsViewModel {
        let allocations = Array(model.importedStocks.stockAllocations.prefix(max(1, top)))
        let imported = ImportedStocksStatisticsView(
            totalPositions: model.importedStocks.totalPositions,
            totalMarketValue: model.importedStocks.totalMarketValue,
            totalCostBasis: model.importedStocks.totalCostBasis,
            totalUnrealizedPnl: model.importedStocks.totalUnrealizedPnl,
            totalRealizedPnl: model.importedStocks.totalRealizedPnl,
            stockSummaries: model.importedStocks.stockSummaries,
            stockAllocations: allocations,
            sectorAllocations: model.importedStocks.sectorAllocations,
            calendarPerformance: []
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: imported,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func trimForSector(_ model: StatisticsViewModel) -> StatisticsViewModel {
        let imported = ImportedStocksStatisticsView(
            totalPositions: model.importedStocks.totalPositions,
            totalMarketValue: model.importedStocks.totalMarketValue,
            totalCostBasis: model.importedStocks.totalCostBasis,
            totalUnrealizedPnl: model.importedStocks.totalUnrealizedPnl,
            totalRealizedPnl: model.importedStocks.totalRealizedPnl,
            stockSummaries: [],
            stockAllocations: [],
            sectorAllocations: model.importedStocks.sectorAllocations,
            calendarPerformance: []
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: imported,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func trimForCalendar(_ model: StatisticsViewModel) -> StatisticsViewModel {
        let imported = ImportedStocksStatisticsView(
            totalPositions: model.importedStocks.totalPositions,
            totalMarketValue: model.importedStocks.totalMarketValue,
            totalCostBasis: model.importedStocks.totalCostBasis,
            totalUnrealizedPnl: model.importedStocks.totalUnrealizedPnl,
            totalRealizedPnl: model.importedStocks.totalRealizedPnl,
            stockSummaries: [],
            stockAllocations: [],
            sectorAllocations: [],
            calendarPerformance: model.importedStocks.calendarPerformance
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: imported,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func trimForContributions(_ model: StatisticsViewModel, top: Int) -> StatisticsViewModel {
        let topSummaries = Array(
            model.importedStocks.stockSummaries
                .sorted(by: { abs($0.unrealizedPnl) > abs($1.unrealizedPnl) })
                .prefix(max(1, top))
        )
        let imported = ImportedStocksStatisticsView(
            totalPositions: model.importedStocks.totalPositions,
            totalMarketValue: model.importedStocks.totalMarketValue,
            totalCostBasis: model.importedStocks.totalCostBasis,
            totalUnrealizedPnl: model.importedStocks.totalUnrealizedPnl,
            totalRealizedPnl: model.importedStocks.totalRealizedPnl,
            stockSummaries: topSummaries,
            stockAllocations: [],
            sectorAllocations: [],
            calendarPerformance: []
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: imported,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func trimForWinnersLosers(_ model: StatisticsViewModel, top: Int) -> StatisticsViewModel {
        let winners = model.importedStocks.stockSummaries
            .filter { $0.unrealizedPnl >= 0 }
            .sorted(by: { $0.unrealizedPnl > $1.unrealizedPnl })
        let losers = model.importedStocks.stockSummaries
            .filter { $0.unrealizedPnl < 0 }
            .sorted(by: { $0.unrealizedPnl < $1.unrealizedPnl })

        let combined = Array(winners.prefix(max(1, top))) + Array(losers.prefix(max(1, top)))
        let imported = ImportedStocksStatisticsView(
            totalPositions: model.importedStocks.totalPositions,
            totalMarketValue: model.importedStocks.totalMarketValue,
            totalCostBasis: model.importedStocks.totalCostBasis,
            totalUnrealizedPnl: model.importedStocks.totalUnrealizedPnl,
            totalRealizedPnl: model.importedStocks.totalRealizedPnl,
            stockSummaries: combined,
            stockAllocations: [],
            sectorAllocations: [],
            calendarPerformance: []
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: imported,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func trimForVolatility(_ model: StatisticsViewModel, top: Int) -> StatisticsViewModel {
        let volatile = Array(
            model.market.heatmap
                .sorted(by: { abs($0.changePercent) > abs($1.changePercent) })
                .prefix(max(1, top))
        )
        let market = MarketStatisticsView(
            benchmarkSymbol: model.market.benchmarkSymbol,
            benchmarkChange1D: model.market.benchmarkChange1D,
            benchmarkChange1W: model.market.benchmarkChange1W,
            benchmarkChange1M: model.market.benchmarkChange1M,
            benchmarkChangeYtd: model.market.benchmarkChangeYtd,
            heatmap: volatile
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: model.importedStocks,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: market
        )
    }

    func trimForCurrency(_ model: StatisticsViewModel, top: Int) -> StatisticsViewModel {
        let topHeatmap = Array(model.market.heatmap.prefix(max(1, top)))
        let market = MarketStatisticsView(
            benchmarkSymbol: model.market.benchmarkSymbol,
            benchmarkChange1D: model.market.benchmarkChange1D,
            benchmarkChange1W: model.market.benchmarkChange1W,
            benchmarkChange1M: model.market.benchmarkChange1M,
            benchmarkChangeYtd: model.market.benchmarkChangeYtd,
            heatmap: topHeatmap
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: model.importedStocks,
            watchlist: model.watchlist,
            looklist: model.looklist,
            market: market
        )
    }

    func trimForScenarioTracking(_ model: StatisticsViewModel) -> StatisticsViewModel {
        let looklist = LooklistStatisticsView(
            totalIdeas: model.looklist.totalIdeas,
            activeIdeas: model.looklist.activeIdeas,
            ideasWithTarget: model.looklist.ideasWithTarget,
            ideasByConviction: model.looklist.ideasByConviction
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: model.importedStocks,
            watchlist: model.watchlist,
            looklist: looklist,
            market: model.market
        )
    }

    func trimForNotesQuality(_ model: StatisticsViewModel) -> StatisticsViewModel {
        let watchlist = WatchlistStatisticsView(
            totalSymbols: model.watchlist.totalSymbols,
            symbolsWithNotes: model.watchlist.symbolsWithNotes,
            sectorAllocations: [],
            topWatched: model.watchlist.topWatched
        )
        return StatisticsViewModel(
            generatedAt: model.generatedAt,
            importedStocks: model.importedStocks,
            watchlist: watchlist,
            looklist: model.looklist,
            market: model.market
        )
    }

    func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func normalizeScenario(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func uniqueSymbols(from values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let symbol = normalizeSymbol(value)
            guard !symbol.isEmpty, !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            result.append(symbol)
        }
        return result
    }

    func inferSector(for symbol: String, notes: [ResearchNote]) -> String {
        let blob = notes
            .flatMap { [$0.title ?? "", $0.thesis, $0.risks ?? "", $0.catalysts ?? ""] }
            .joined(separator: " ")
            .lowercased()

        if blob.contains("bank") || blob.contains("insurance") || blob.contains("financial") {
            return "Financials"
        }
        if blob.contains("semiconductor") || blob.contains("software") || blob.contains("cloud") || blob.contains("ai") {
            return "Technology"
        }
        if blob.contains("oil") || blob.contains("gas") || blob.contains("energy") {
            return "Energy"
        }
        if blob.contains("health") || blob.contains("pharma") || blob.contains("biotech") {
            return "Healthcare"
        }
        if blob.contains("retail") || blob.contains("consumer") {
            return "Consumer"
        }
        if blob.contains("industrial") || blob.contains("manufacturing") {
            return "Industrials"
        }

        if symbol.hasPrefix("XLE") { return "Energy" }
        if symbol.hasPrefix("XLK") { return "Technology" }
        if symbol.hasPrefix("XLF") { return "Financials" }
        if symbol.hasPrefix("XLV") { return "Healthcare" }
        return "Unknown"
    }

    func referencePrice(history: [PriceHistory], beforeOrAt date: Date) -> Double? {
        history.last(where: { startOfDay($0.date) <= startOfDay(date) })?.close
    }

    func percentChange(current: Double?, reference: Double?) -> Double? {
        guard let current, let reference, reference != 0 else { return nil }
        return (current - reference) / reference * 100
    }

    func percentage(_ value: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return round2((value / total) * 100)
    }

    func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }

    func startOfYear(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let year = calendar.component(.year, from: date)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? startOfDay(date)
    }

    func addDays(_ date: Date, days: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) ?? date
    }

    func defaultFromDate(period: StatisticsPeriod, asOf: Date) -> Date? {
        switch period {
        case .oneWeek, .oneMonth, .threeMonths, .sixMonths, .oneYear:
            guard let days = period.dayWindow else { return nil }
            // Fetch additional lookback to support daily/weekly/monthly deltas in the same query.
            return addDays(asOf, days: -max(days, 400))
        case .ytd:
            return startOfYear(asOf)
        case .all:
            return addDays(asOf, days: -730)
        }
    }
}
