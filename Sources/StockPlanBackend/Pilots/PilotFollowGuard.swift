import Fluent
import Foundation
import Vapor

/// Keeps hand edits out of a portfolio a pilot follow manages.
///
/// The mirror rebalances from the portfolio's holdings and the pilot account's
/// simulated cash. A share added by hand arrives without cash, so the next
/// rebalance would sell it for money that never existed; a hand sale would
/// credit real-looking cash to a simulation. Any follow row, paused or not,
/// counts: a paused follow resumes against whatever the portfolio holds.
enum PilotFollowGuard {
    static func ensureNotFollowed(portfolioListId: UUID, on db: any Database) async throws {
        if try await isFollowed(portfolioListId: portfolioListId, on: db) {
            throw Abort(.conflict, reason: "This portfolio is managed by a pilot follow. Stop following to edit it.")
        }
    }

    /// For writers that must not throw (a background sync): they skip instead.
    static func isFollowed(portfolioListId: UUID, on db: any Database) async throws -> Bool {
        try await PilotFollow.query(on: db)
            .filter(\.$portfolioListId == portfolioListId)
            .count() > 0
    }
}
