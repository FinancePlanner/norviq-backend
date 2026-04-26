@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Projection Scenarios Tests", .serialized)
struct ProjectionScenariosTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func makeRequest(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    @Test("Make scenarios base case generates bear, base, and bull with correct shifts")
    func makeScenariosBase() async throws {
        try await withApp { app in
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let metrics = StockAnalysisMetricsResponse(
                symbol: "AAPL",
                ttmPE: 20,
                forwardPE: 18,
                twoYearForwardPE: nil,
                ttmEPSGrowth: 0.1,
                currentYearExpectedEPSGrowth: 0.1,
                nextYearEPSGrowth: nil,
                ttmRevenueGrowth: 0.1,
                currentYearExpectedRevenueGrowth: nil,
                nextYearRevenueGrowth: nil,
                grossMargin: 0.4,
                netMargin: 0.2,
                ttmPEGRatio: nil,
                lastYearEPSGrowth: nil,
                ttmVsNTMEPSGrowth: nil,
                currentQuarterEPSGrowthVsPreviousYear: nil,
                twoYearStackExpectedEPSGrowth: nil,
                lastYearRevenueGrowth: nil,
                ttmVsNTMRevenueGrowth: nil,
                currentQuarterRevenueGrowthVsPreviousYear: nil,
                twoYearStackExpectedRevenueGrowth: nil,
                currentPrice: 100,
                marketCap: 1000,
                sharesOutstanding: 10,
                baseYear: 2025,
                yearlyProjections: [
                    YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.1, netIncome: 20, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2.0, fcf: nil, fcfMargin: nil),
                ],
                wacc: nil,
                terminalGrowthRate: 0.025,
                terminalMargin: 0.22,
                exitPELow: nil,
                exitPEHigh: nil,
                dcfBasePrice: nil,
                dcfBearPrice: nil,
                dcfBullPrice: nil,
                netDebt: nil
            )

            let scenarios = service.makeProjectionScenarios(from: metrics, fallbackCurrentPrice: 100, fallbackMarketCap: 1000, fallbackSharesOutstanding: 10)

            #expect(scenarios.count == 3)
            let bear = try #require(scenarios.first { $0.kind == "bear" })
            let base = try #require(scenarios.first { $0.kind == "base" })
            let bull = try #require(scenarios.first { $0.kind == "bull" })

            let baseY1 = try #require(base.years.first { $0.year == 2026 })
            #expect(baseY1.revenueGrowth == 0.1)

            let bearY1 = try #require(bear.years.first { $0.year == 2026 })
            #expect(bearY1.revenueGrowth < 0.1) // shifted down

            let bullY1 = try #require(bull.years.first { $0.year == 2026 })
            #expect(bullY1.revenueGrowth > 0.1) // shifted up

            #expect(bearY1.peLowEstimate < baseY1.peLowEstimate)
            #expect(bullY1.peHighEstimate > baseY1.peHighEstimate)
        }
    }

    @Test("Make scenarios fallback triggered by missing projections")
    func makeScenariosFallbackMissingProjections() async throws {
        try await withApp { app in
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let metrics = StockAnalysisMetricsResponse(
                symbol: "AAPL",
                ttmPE: nil, forwardPE: nil, twoYearForwardPE: nil, ttmEPSGrowth: nil, currentYearExpectedEPSGrowth: nil, nextYearEPSGrowth: nil, ttmRevenueGrowth: nil, currentYearExpectedRevenueGrowth: nil, nextYearRevenueGrowth: nil, grossMargin: nil, netMargin: nil, ttmPEGRatio: nil, lastYearEPSGrowth: nil, ttmVsNTMEPSGrowth: nil, currentQuarterEPSGrowthVsPreviousYear: nil, twoYearStackExpectedEPSGrowth: nil, lastYearRevenueGrowth: nil, ttmVsNTMRevenueGrowth: nil, currentQuarterRevenueGrowthVsPreviousYear: nil, twoYearStackExpectedRevenueGrowth: nil, currentPrice: 100, marketCap: 1000, sharesOutstanding: 10, baseYear: nil,
                yearlyProjections: nil, // Missing projections
                wacc: nil, terminalGrowthRate: nil, terminalMargin: nil, exitPELow: nil, exitPEHigh: nil, dcfBasePrice: nil, dcfBearPrice: nil, dcfBullPrice: nil, netDebt: nil
            )

            let scenarios = service.makeProjectionScenarios(from: metrics, fallbackCurrentPrice: 100, fallbackMarketCap: 1000, fallbackSharesOutstanding: 10)

            #expect(scenarios.count == 3)
            let base = try #require(scenarios.first { $0.kind == "base" })
            let baseY1 = try #require(base.years.first)
            // Base growth is 0.07 in fallback
            #expect(abs(baseY1.revenueGrowth - 0.07) < 0.001)
        }
    }

    @Test("Make scenarios fallback triggered by zero shares")
    func makeScenariosFallbackZeroShares() async throws {
        try await withApp { app in
            let service = StockServiceImpl(repo: DatabaseStocksRepository(), req: makeRequest(app))
            let metrics = StockAnalysisMetricsResponse(
                symbol: "AAPL",
                ttmPE: nil, forwardPE: nil, twoYearForwardPE: nil, ttmEPSGrowth: nil, currentYearExpectedEPSGrowth: nil, nextYearEPSGrowth: nil, ttmRevenueGrowth: nil, currentYearExpectedRevenueGrowth: nil, nextYearRevenueGrowth: nil, grossMargin: nil, netMargin: nil, ttmPEGRatio: nil, lastYearEPSGrowth: nil, ttmVsNTMEPSGrowth: nil, currentQuarterEPSGrowthVsPreviousYear: nil, twoYearStackExpectedEPSGrowth: nil, lastYearRevenueGrowth: nil, ttmVsNTMRevenueGrowth: nil, currentQuarterRevenueGrowthVsPreviousYear: nil, twoYearStackExpectedRevenueGrowth: nil, currentPrice: 100, marketCap: 1000,
                sharesOutstanding: 0, // Zero shares
                baseYear: nil,
                yearlyProjections: [
                    YearlyProjectionResponse(year: 2026, revenue: 100, revenueGrowth: 0.1, netIncome: 20, netIncomeGrowth: 0.1, netMargin: 0.2, eps: 2.0, fcf: nil, fcfMargin: nil),
                ],
                wacc: nil, terminalGrowthRate: nil, terminalMargin: nil, exitPELow: nil, exitPEHigh: nil, dcfBasePrice: nil, dcfBearPrice: nil, dcfBullPrice: nil, netDebt: nil
            )

            let scenarios = service.makeProjectionScenarios(from: metrics, fallbackCurrentPrice: 100, fallbackMarketCap: 1000, fallbackSharesOutstanding: 10) // Will use fallbackShares 10

            #expect(scenarios.count == 3)
            let base = try #require(scenarios.first { $0.kind == "base" })
            let baseY1 = try #require(base.years.first)
            #expect(abs(baseY1.revenueGrowth - 0.07) < 0.001)
        }
    }
}
