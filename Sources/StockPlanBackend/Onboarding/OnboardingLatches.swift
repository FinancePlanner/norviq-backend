import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// A guided-start latch and the column it stamps.
enum OnboardingLatch: String, CaseIterable, Sendable {
    case holding = "first_holding_at"
    case budget = "first_budget_at"
    case goal = "first_goal_at"
}

extension AssetCategory {
    /// Crypto does not count toward `add_holding`: the step teaches the
    /// portfolio of stocks and funds the rest of the app builds on.
    /// Contract: norviq-shared/docs/guided-start.md.
    var countsTowardAddHolding: Bool {
        self != .crypto
    }
}

enum OnboardingLatches {
    /// Stamps the latch once. The row may not exist yet — a user can add a
    /// holding before any client has read onboarding state — so this upserts.
    static func latch(_ latch: OnboardingLatch, userId: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let column = latch.rawValue
        try await sql.raw("""
        INSERT INTO onboarding_state (id, user_id, \(unsafeRaw: column), created_at, updated_at)
        VALUES (\(bind: UUID()), \(bind: userId), NOW(), NOW(), NOW())
        ON CONFLICT (user_id) DO UPDATE
        SET \(unsafeRaw: column) = COALESCE(onboarding_state.\(unsafeRaw: column), EXCLUDED.\(unsafeRaw: column)),
            updated_at = NOW()
        """).run()
    }
}

extension Request {
    /// Best-effort: the user's action already succeeded, and a missed latch
    /// only costs a guided-start tick.
    func latchOnboarding(_ latch: OnboardingLatch, userId: UUID, on db: any Database) async {
        do {
            try await OnboardingLatches.latch(latch, userId: userId, on: db)
        } catch {
            logger.warning("onboarding latch failed latch=\(latch.rawValue) user=\(userId) error=\(error)")
        }
    }
}
