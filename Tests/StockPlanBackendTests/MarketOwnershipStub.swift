import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor

// The stub upstream behind `MarketOwnershipServiceTests`.

// MARK: - Recorded state

/// Canned answers plus a record of what was asked for.
///
/// Recording is the point: the pagination cut-offs, the quarter fallback and
/// the "do not cache a degraded response" rule are all statements about which
/// upstream calls happen, and none of them is visible in the response body.
actor OwnershipStub {
    // Insider
    var insiderPages: [Int: [FMPInsiderTrade]] = [:]
    var insiderErrors: [Int: any Error] = [:]
    private(set) var insiderPagesRequested: [Int] = []

    // Congress. The two chambers fail independently, because the service is
    // meant to keep one when the other does not answer.
    var senate: [FMPCongressTrade] = []
    var house: [FMPCongressTrade] = []
    var senateLatest: [FMPCongressTrade] = []
    var houseLatest: [FMPCongressTrade] = []
    var senateError: (any Error)?
    var houseError: (any Error)?
    private(set) var latestLimitsRequested: [Int] = []

    // Institutional
    var holdersByQuarter: [String: [FMPInstitutionalHolder]] = [:]
    var holdersError: (any Error)?
    var summary: [FMPInstitutionalPositionsSummary] = []
    private(set) var holderQuartersRequested: [String] = []
    private(set) var summaryQuartersRequested: [String] = []

    func insiderPage(_ page: Int) throws -> [FMPInsiderTrade] {
        insiderPagesRequested.append(page)
        if let error = insiderErrors[page] {
            throw error
        }
        return insiderPages[page] ?? []
    }

    func senateTrades() throws -> [FMPCongressTrade] {
        if let senateError {
            throw senateError
        }
        return senate
    }

    func houseTrades() throws -> [FMPCongressTrade] {
        if let houseError {
            throw houseError
        }
        return house
    }

    func senateLatestTrades(limit: Int) throws -> [FMPCongressTrade] {
        latestLimitsRequested.append(limit)
        if let senateError {
            throw senateError
        }
        return senateLatest
    }

    func houseLatestTrades(limit: Int) throws -> [FMPCongressTrade] {
        latestLimitsRequested.append(limit)
        if let houseError {
            throw houseError
        }
        return houseLatest
    }

    func holders(quarter: String) throws -> [FMPInstitutionalHolder] {
        holderQuartersRequested.append(quarter)
        if let holdersError {
            throw holdersError
        }
        return holdersByQuarter[quarter] ?? []
    }

    func positionsSummary(quarter: String) -> [FMPInstitutionalPositionsSummary] {
        summaryQuartersRequested.append(quarter)
        return summary
    }

    /// Setters (an actor's properties cannot be assigned from outside it).
    func setInsiderPages(_ pages: [Int: [FMPInsiderTrade]]) {
        insiderPages = pages
    }

    func setInsiderError(_ error: any Error, onPage page: Int) {
        insiderErrors[page] = error
    }

    func setSenate(_ rows: [FMPCongressTrade]) {
        senate = rows
    }

    func setHouse(_ rows: [FMPCongressTrade]) {
        house = rows
    }

    func setSenateLatest(_ rows: [FMPCongressTrade]) {
        senateLatest = rows
    }

    func setHouseLatest(_ rows: [FMPCongressTrade]) {
        houseLatest = rows
    }

    func setSenateError(_ error: (any Error)?) {
        senateError = error
    }

    func setHouseError(_ error: (any Error)?) {
        houseError = error
    }

    func setHolders(_ rows: [FMPInstitutionalHolder], quarter: String) {
        holdersByQuarter[quarter] = rows
    }

    func setHoldersError(_ error: (any Error)?) {
        holdersError = error
    }

    func setSummary(_ rows: [FMPInstitutionalPositionsSummary]) {
        summary = rows
    }
}

/// Answers the ownership calls from `OwnershipStub`; every other
/// `FMPMarketDataProvider` requirement is out of scope and says so.
struct OwnershipStubProvider: FMPMarketDataProvider {
    let name = "ownership-stub"
    let state: OwnershipStub

    private var unsupported: Abort {
        Abort(.notImplemented, reason: "The ownership stub does not serve this endpoint.")
    }

    // MARK: Ownership

    func fetchInsiderTrades(symbol _: String, page: Int, limit _: Int, on _: Request) async throws
        -> [FMPInsiderTrade]
    {
        try await state.insiderPage(page)
    }

    func senateTrades(symbol _: String, on _: Request) async throws -> [FMPCongressTrade] {
        try await state.senateTrades()
    }

    func houseTrades(symbol _: String, on _: Request) async throws -> [FMPCongressTrade] {
        try await state.houseTrades()
    }

    func latestSenateTrades(limit: Int, on _: Request) async throws -> [FMPCongressTrade] {
        try await state.senateLatestTrades(limit: limit)
    }

    func latestHouseTrades(limit: Int, on _: Request) async throws -> [FMPCongressTrade] {
        try await state.houseLatestTrades(limit: limit)
    }

    func institutionalHolders(symbol _: String, year: Int, quarter: Int, on _: Request) async throws
        -> [FMPInstitutionalHolder]
    {
        try await state.holders(quarter: "\(year)Q\(quarter)")
    }

    func institutionalPositionsSummary(symbol _: String, year: Int, quarter: Int, on _: Request) async
        -> [FMPInstitutionalPositionsSummary]
    {
        await state.positionsSummary(quarter: "\(year)Q\(quarter)")
    }

    // MARK: Out of scope

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

    func earnings(symbol _: String, limit _: Int?, on _: Request) async throws -> [EarningsResponse] {
        throw unsupported
    }

    func earningsCalendar(from _: Date?, to _: Date?, on _: Request) async throws -> [EarningsResponse] {
        throw unsupported
    }

    func earningsTranscript(symbol _: String, date _: String?, year _: Int?, quarter _: Int?, on _: Request)
        async throws -> EarningsTranscriptResponse
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

    func fetchInsiderTrades(symbol _: String, limit _: Int, on _: Request) async throws -> [FMPInsiderTrade] {
        throw unsupported
    }
}
