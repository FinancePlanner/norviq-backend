import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor

// The stub upstream behind `RecentEarningsServiceTests`.

/// Canned earnings history plus a count of how many times it was asked for.
///
/// The count is the point: "the teaser is served from its own cache" is a
/// statement about which upstream calls happen, and nothing in the response
/// body shows it.
actor RecentEarningsStub {
    var rows: [EarningsResponse] = []
    private(set) var earningsCalls = 0

    func earnings() -> [EarningsResponse] {
        earningsCalls += 1
        return rows
    }

    /// Setter (an actor's properties cannot be assigned from outside it).
    func setRows(_ rows: [EarningsResponse]) {
        self.rows = rows
    }
}

/// Answers `earnings` from `RecentEarningsStub`; every other
/// `FMPMarketDataProvider` requirement without a protocol default is out of
/// scope and says so.
///
/// `earningsTranscript` fails loudly rather than returning a canned transcript:
/// the teaser must never reach it, and a stub that quietly answered would hide
/// that.
struct RecentEarningsStubProvider: FMPMarketDataProvider {
    let name = "recent-earnings-stub"
    let state: RecentEarningsStub

    private var unsupported: Abort {
        Abort(.notImplemented, reason: "The recent-earnings stub does not serve this endpoint.")
    }

    // MARK: In scope

    func earnings(symbol _: String, limit _: Int?, on _: Request) async throws -> [EarningsResponse] {
        await state.earnings()
    }

    // MARK: Must not be reached

    func earningsTranscript(symbol _: String, date _: String?, year _: Int?, quarter _: Int?, on _: Request)
        async throws -> EarningsTranscriptResponse
    {
        throw Abort(.internalServerError, reason: "The earnings teaser must not fetch a transcript.")
    }

    // MARK: Out of scope

    func earningsCalendar(from _: Date?, to _: Date?, on _: Request) async throws -> [EarningsResponse] {
        throw unsupported
    }

    func cashFlowStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws
        -> [CashFlowStatementResponse]
    {
        throw unsupported
    }

    func incomeStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws
        -> [IncomeStatementResponse]
    {
        throw unsupported
    }

    func balanceSheetStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws
        -> [BalanceSheetStatementResponse]
    {
        throw unsupported
    }

    func ratiosTTM(symbol _: String, on _: Request) async throws -> [RatiosTTMResponse] {
        throw unsupported
    }

    func gradesConsensus(symbol _: String, on _: Request) async throws -> [GradesConsensusResponse] {
        throw unsupported
    }

    func financialGrowth(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws
        -> [FinancialGrowthResponse]
    {
        throw unsupported
    }

    func analystEstimates(symbol _: String, period _: String, page _: Int?, limit _: Int?, on _: Request)
        async throws -> [AnalystEstimatesResponse]
    {
        throw unsupported
    }

    func ratios(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws
        -> [RatiosResponse]
    {
        throw unsupported
    }

    func historicalSectorPerformance(
        sector _: String, exchange _: String?, from _: Date?, to _: Date?, on _: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        throw unsupported
    }

    func fetchGeneralMarketNews(page _: Int?, limit _: Int?, from _: Date?, to _: Date?, on _: Request)
        async throws -> [FMPMarketNewsItem]
    {
        throw unsupported
    }

    func stockIntraday(interval _: String, symbol _: String, from _: String?, to _: String?, on _: Request)
        async throws -> [CryptoHistoricalPoint]
    {
        throw unsupported
    }

    func stockHistoricalEOD(symbol _: String, from _: String?, to _: String?, on _: Request) async throws
        -> [CryptoHistoricalLightPoint]
    {
        throw unsupported
    }
}
