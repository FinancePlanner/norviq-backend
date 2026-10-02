import Fluent
import Foundation

/// What a stopped pilot follow leaves in its portfolio: the `broker == "pilot"`
/// account (simulated cash and trades) and the simulated `stocks` rows.
///
/// Deleting the follow keeps them, so the user can still look at the result.
/// Deleting the portfolio removes them with it; they never count as a
/// connected account and never move into another portfolio. Only for a
/// portfolio with no follow: a followed one is still the mirror's.
enum PilotPortfolioLeftovers {
    /// Pilot accounts attached to the portfolio.
    static func accounts(portfolioListId: UUID, on db: any Database) async throws -> [Account] {
        try await Account.query(on: db)
            .filter(\.$portfolioId == portfolioListId)
            .filter(\.$broker == PilotAccountResolver.broker)
            .all()
    }

    /// Run inside the transaction that deletes the portfolio.
    static func remove(portfolioListId: UUID, on db: any Database) async throws {
        try await Stock.query(on: db)
            .filter(\.$portfolioListId == portfolioListId)
            .filter(\.$sourceProvider == PilotAccountResolver.broker)
            .delete()
        for account in try await accounts(portfolioListId: portfolioListId, on: db) {
            let accountId = try account.requireID()
            try await CashBalance.query(on: db).filter(\.$accountId == accountId).delete()
            try await Transaction.query(on: db).filter(\.$accountId == accountId).delete()
            try await account.delete(on: db)
        }
    }
}
