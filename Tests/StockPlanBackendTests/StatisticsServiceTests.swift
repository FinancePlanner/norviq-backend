@testable import StockPlanBackend
import Fluent
import Foundation
import NIOCore
import Testing
import Vapor

@Suite("StatisticsService Tests")
struct StatisticsServiceTests {
    @Test("overviewStatistics uses default query options")
    func overviewUsesDefaults() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        _ = try await service.overviewStatistics(
            userId: UUID(),
            query: .init(period: nil, top: nil, benchmark: nil, asOf: nil),
            on: UnusedDatabase()
        )

        let options = await repo.lastOptions(for: "overviewStatistics")
        #expect(options != nil)
        #expect(options?.period == .oneMonth)
        #expect(options?.top == 10)
        #expect(options?.benchmarkSymbol == "SPY")
        #expect(options?.asOfDate == nil)
    }

    @Test("service normalizes valid query values")
    func serviceNormalizesQueryValues() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        _ = try await service.marketStatistics(
            userId: UUID(),
            query: .init(period: "week", top: 7, benchmark: " qqq ", asOf: "2025-01-10"),
            on: UnusedDatabase()
        )

        let options = await repo.lastOptions(for: "marketStatistics")
        #expect(options?.period == .oneWeek)
        #expect(options?.top == 7)
        #expect(options?.benchmarkSymbol == "QQQ")
        #expect(Self.formatDateOnly(options?.asOfDate) == "2025-01-10")
    }

    @Test("invalid period returns badRequest")
    func invalidPeriod() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        do {
            _ = try await service.overviewStatistics(
                userId: UUID(),
                query: .init(period: "2w", top: nil, benchmark: nil, asOf: nil),
                on: UnusedDatabase()
            )
            #expect(Bool(false), "Expected badRequest for invalid period")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("period"))
        }
    }

    @Test("invalid top returns badRequest")
    func invalidTop() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        do {
            _ = try await service.overviewStatistics(
                userId: UUID(),
                query: .init(period: nil, top: 0, benchmark: nil, asOf: nil),
                on: UnusedDatabase()
            )
            #expect(Bool(false), "Expected badRequest for invalid top")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("top"))
        }
    }

    @Test("invalid benchmark returns badRequest")
    func invalidBenchmark() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        do {
            _ = try await service.overviewStatistics(
                userId: UUID(),
                query: .init(period: nil, top: nil, benchmark: "S P Y", asOf: nil),
                on: UnusedDatabase()
            )
            #expect(Bool(false), "Expected badRequest for invalid benchmark")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("benchmark"))
        }
    }

    @Test("invalid asOf format returns badRequest")
    func invalidAsOfFormat() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        do {
            _ = try await service.overviewStatistics(
                userId: UUID(),
                query: .init(period: nil, top: nil, benchmark: nil, asOf: "2025/01/10"),
                on: UnusedDatabase()
            )
            #expect(Bool(false), "Expected badRequest for invalid asOf")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("asOf"))
        }
    }

    @Test("future asOf returns badRequest")
    func futureAsOf() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)

        let tomorrow = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let asOf = Self.formatDateOnly(tomorrow)

        do {
            _ = try await service.overviewStatistics(
                userId: UUID(),
                query: .init(period: nil, top: nil, benchmark: nil, asOf: asOf),
                on: UnusedDatabase()
            )
            #expect(Bool(false), "Expected badRequest for future asOf")
        } catch let abort as Abort {
            #expect(abort.status == .badRequest)
            #expect(abort.reason.contains("future"))
        }
    }

    @Test("service maps repository model to DTO")
    func mapsModelToDTO() async throws {
        let fixture = StatisticsViewModel.fixture()
        let repo = StatisticsRepositorySpy(model: fixture)
        let service = DefaultStatisticsService(repo: repo)

        let response = try await service.importedStocksStatistics(
            userId: UUID(),
            query: .init(period: "1m", top: 5, benchmark: "SPY", asOf: "2025-01-10"),
            on: UnusedDatabase()
        )

        #expect(response.generatedAt == ISO8601DateFormatter().string(from: fixture.generatedAt))
        #expect(response.importedStocks.totalPositions == 2)
        #expect(response.importedStocks.stockSummaries.count == 2)
        #expect(response.importedStocks.stockSummaries.first?.symbol == "AAPL")
        #expect(response.importedStocks.stockSummaries.first?.dailyChangePercent == 1.25)
        #expect(response.importedStocks.stockSummaries.first?.weeklyChangePercent == 2.5)
        #expect(response.importedStocks.stockSummaries.first?.monthlyChangePercent == 5)
        #expect(response.market.benchmarkSymbol == "SPY")
    }

    @Test("each service endpoint delegates to matching repository method")
    func serviceDelegation() async throws {
        let repo = StatisticsRepositorySpy(model: .fixture())
        let service = DefaultStatisticsService(repo: repo)
        let query = StatisticsQueryInput(period: "1m", top: 3, benchmark: "SPY", asOf: "2025-01-10")
        let userId = UUID()
        let db = UnusedDatabase()

        _ = try await service.stockLevelScorecard(userId: userId, query: query, on: db)
        _ = try await service.stockAllocation(userId: userId, query: query, on: db)
        _ = try await service.sectorAllocation(userId: userId, query: query, on: db)
        _ = try await service.calendarPerformance(userId: userId, query: query, on: db)
        _ = try await service.contributionAnalysis(userId: userId, query: query, on: db)
        _ = try await service.winnersVsLosers(userId: userId, query: query, on: db)
        _ = try await service.volatilitySnapshot(userId: userId, query: query, on: db)
        _ = try await service.currencySplit(userId: userId, query: query, on: db)
        _ = try await service.scenarioTracking(userId: userId, query: query, on: db)
        _ = try await service.notesQualityMetrics(userId: userId, query: query, on: db)
        _ = try await service.importedStocksStatistics(userId: userId, query: query, on: db)
        _ = try await service.watchlistStatistics(userId: userId, query: query, on: db)
        _ = try await service.looklistStatistics(userId: userId, query: query, on: db)
        _ = try await service.marketStatistics(userId: userId, query: query, on: db)
        _ = try await service.overviewStatistics(userId: userId, query: query, on: db)

        let called = await repo.invocations()
        #expect(called == [
            "stockLevelScorecard",
            "stockAllocation",
            "sectorAllocation",
            "calendarPerformance",
            "contributionAnalysis",
            "winnersVsLosers",
            "volatilitySnapshot",
            "currencySplit",
            "scenarioTracking",
            "notesQualityMetrics",
            "importedStocksStatistics",
            "watchlistStatistics",
            "looklistStatistics",
            "marketStatistics",
            "overviewStatistics",
        ])
    }

    private static func formatDateOnly(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private actor StatisticsRepositorySpy: StatisticsRepository {
    private var model: StatisticsViewModel
    private var calledMethods: [String] = []
    private var lastOptionsByMethod: [String: StatisticsQueryOptions] = [:]

    init(model: StatisticsViewModel) {
        self.model = model
    }

    func invocations() -> [String] {
        calledMethods
    }

    func lastOptions(for method: String) -> StatisticsQueryOptions? {
        lastOptionsByMethod[method]
    }

    private func record(_ method: String, options: StatisticsQueryOptions) -> StatisticsViewModel {
        calledMethods.append(method)
        lastOptionsByMethod[method] = options
        return model
    }

    func stockLevelScorecard(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("stockLevelScorecard", options: options)
    }

    func stockAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("stockAllocation", options: options)
    }

    func sectorAllocation(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("sectorAllocation", options: options)
    }

    func calendarPerformance(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("calendarPerformance", options: options)
    }

    func contributionAnalysis(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("contributionAnalysis", options: options)
    }

    func winnersVsLosers(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("winnersVsLosers", options: options)
    }

    func volatilitySnapshot(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("volatilitySnapshot", options: options)
    }

    func currencySplit(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("currencySplit", options: options)
    }

    func scenarioTracking(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("scenarioTracking", options: options)
    }

    func notesQualityMetrics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("notesQualityMetrics", options: options)
    }

    func importedStocksStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("importedStocksStatistics", options: options)
    }

    func watchlistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("watchlistStatistics", options: options)
    }

    func looklistStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("looklistStatistics", options: options)
    }

    func marketStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("marketStatistics", options: options)
    }

    func overviewStatistics(userId: UUID, options: StatisticsQueryOptions, on db: any Database) async throws -> StatisticsViewModel {
        record("overviewStatistics", options: options)
    }
}

private struct UnusedDatabase: Database {
    var context: DatabaseContext {
        fatalError("Unused in StatisticsServiceTests")
    }

    var inTransaction: Bool { false }

    func execute(
        query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        fatalError("Unused in StatisticsServiceTests")
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        fatalError("Unused in StatisticsServiceTests")
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        fatalError("Unused in StatisticsServiceTests")
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        fatalError("Unused in StatisticsServiceTests")
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        fatalError("Unused in StatisticsServiceTests")
    }
}

private extension StatisticsViewModel {
    static func fixture() -> StatisticsViewModel {
        StatisticsViewModel(
            generatedAt: Date(timeIntervalSince1970: 1_735_776_000),
            importedStocks: ImportedStocksStatisticsView(
                totalPositions: 2,
                totalMarketValue: 2_000,
                totalCostBasis: 1_700,
                totalUnrealizedPnl: 300,
                totalRealizedPnl: 50,
                stockSummaries: [
                    .init(
                        symbol: "AAPL",
                        marketValue: 1_250,
                        weightPercent: 62.5,
                        dailyChangePercent: 1.25,
                        weeklyChangePercent: 2.5,
                        monthlyChangePercent: 5.0,
                        unrealizedPnl: 200
                    ),
                    .init(
                        symbol: "MSFT",
                        marketValue: 750,
                        weightPercent: 37.5,
                        dailyChangePercent: -0.5,
                        weeklyChangePercent: 1.0,
                        monthlyChangePercent: 2.0,
                        unrealizedPnl: 100
                    ),
                ],
                stockAllocations: [
                    .init(symbol: "AAPL", value: 1_250, weightPercent: 62.5),
                    .init(symbol: "MSFT", value: 750, weightPercent: 37.5),
                ],
                sectorAllocations: [
                    .init(sector: "Technology", value: 2_000, weightPercent: 100),
                ],
                calendarPerformance: [
                    .init(
                        date: Date(timeIntervalSince1970: 1_735_689_600),
                        pnl: 10,
                        pnlPercent: 0.5,
                        isUpDay: true
                    ),
                ]
            ),
            watchlist: WatchlistStatisticsView(
                totalSymbols: 3,
                symbolsWithNotes: 2,
                sectorAllocations: [.init(sector: "Technology", value: 2, weightPercent: 66.67)],
                topWatched: [.init(symbol: "NVDA", mentionCount: 3)]
            ),
            looklist: LooklistStatisticsView(
                totalIdeas: 2,
                activeIdeas: 1,
                ideasWithTarget: 1,
                ideasByConviction: [.init(conviction: "BULL", count: 1)]
            ),
            market: MarketStatisticsView(
                benchmarkSymbol: "SPY",
                benchmarkChange1D: 0.8,
                benchmarkChange1W: 1.7,
                benchmarkChange1M: 3.1,
                benchmarkChangeYtd: 4.6,
                heatmap: [
                    .init(symbol: "AAPL", changePercent: 1.25),
                    .init(symbol: "MSFT", changePercent: -0.5),
                ]
            )
        )
    }
}
