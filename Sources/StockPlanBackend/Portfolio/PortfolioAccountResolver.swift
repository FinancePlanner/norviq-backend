import Fluent
import Foundation
import Vapor

/// Picks the account a hand edit (a sell, a recorded trade) lands on.
///
/// A portfolio that was once followed keeps its pilot account after the follow
/// is removed: that account holds the portfolio's cash. Routing a later hand
/// edit through `ManualAccountResolver` instead would adopt the user's legacy
/// manual account (real cash) into the simulation, or insert a second
/// `manual-<user>` account and fail on the unique external ID.
enum PortfolioAccountResolver {
    static func forManualEdit(userId: UUID, portfolioId: UUID, on db: any Database) async throws -> Account {
        if let pilot = try await Account.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$broker == PilotAccountResolver.broker)
            .first()
        {
            return pilot
        }
        return try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: portfolioId, on: db)
    }
}
