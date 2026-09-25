import Fluent
import Foundation
import StockPlanShared
import Vapor

struct ResolvedPortfolioFilter: Sendable {
    let portfolioId: UUID?
    let portfolioIds: [UUID]
    let dataOwnerUserId: UUID
    let baseCurrency: String
}

/// One definition of "which holdings does this request mean", shared by the
/// authenticated portfolio routes and the public share route so the two can
/// never disagree about what a portfolio contains.
enum PortfolioFilterResolver {
    static func resolve(
        requestedId: String?,
        userId: UUID,
        ownerOnly: Bool = false,
        on req: Request
    ) async throws -> ResolvedPortfolioFilter {
        guard let requestedId else {
            var actualPortfolioIds = try await PortfolioList.query(on: req.db)
                .filter(\.$userId == userId)
                .filter(\.$mode == PortfolioMode.actual.rawValue)
                .filter(\.$archivedAt == nil)
                .all()
                .compactMap(\.id)
            if actualPortfolioIds.isEmpty {
                actualPortfolioIds = try await [ensureDefaultPortfolioListId(userId: userId, on: req.db)]
            }
            return ResolvedPortfolioFilter(
                portfolioId: nil,
                portfolioIds: actualPortfolioIds,
                dataOwnerUserId: userId,
                baseCurrency: "USD"
            )
        }
        guard let portfolioId = UUID(uuidString: requestedId) else {
            throw Abort(.badRequest, reason: "Invalid portfolio ID.")
        }
        let context = try await req.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: userId,
            ownerOnly: ownerOnly,
            on: req.db
        )
        return ResolvedPortfolioFilter(
            portfolioId: portfolioId,
            portfolioIds: [portfolioId],
            dataOwnerUserId: context.portfolio.userId,
            baseCurrency: context.portfolio.baseCurrency
        )
    }

    /// Prices the filter's holdings the same way `/v1/portfolio/summary` does.
    static func loadValuation(_ filter: ResolvedPortfolioFilter, on req: Request) async throws -> PortfolioValuation {
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
            .filter(\.$portfolioListId ~~ filter.portfolioIds)
            .all()
        let cashBalance = try await PortfolioCashResolver.totalCashBalance(
            userId: filter.dataOwnerUserId,
            portfolioId: filter.portfolioId,
            on: req.db
        )
        return try await req.application.portfolioValuationService.value(
            stocks: stocks,
            cashBalance: cashBalance,
            asOf: Date(),
            on: req
        )
    }
}
