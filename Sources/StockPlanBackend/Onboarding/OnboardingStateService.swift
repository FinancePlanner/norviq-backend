import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

enum OnboardingStateService {
    /// Reads the user's row, creating an empty one first if needed. The insert
    /// is `ON CONFLICT DO NOTHING` so two first reads racing both succeed.
    static func fetchOrCreate(userId: UUID, on db: any Database) async throws -> OnboardingState {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("""
            INSERT INTO onboarding_state (id, user_id, created_at, updated_at)
            VALUES (\(bind: UUID()), \(bind: userId), NOW(), NOW())
            ON CONFLICT (user_id) DO NOTHING
            """).run()
        }
        guard let row = try await OnboardingState.query(on: db).filter(\.$userId == userId).first() else {
            throw Abort(.internalServerError, reason: "Onboarding state is missing")
        }
        return row
    }

    static func apply(
        _ patch: OnboardingPatchRequest,
        userId: UUID,
        on db: any Database,
        now: Date = Date()
    ) async throws -> OnboardingState {
        let row = try await fetchOrCreate(userId: userId, on: db)
        if let step = patch.funnelStep {
            row.funnelStep = step
        }
        if patch.funnelCompleted == true, row.funnelCompletedAt == nil {
            row.funnelCompletedAt = now
        }
        if let dismissed = patch.guidedStartDismissed {
            row.guidedStartDismissedAt = dismissed ? (row.guidedStartDismissedAt ?? now) : nil
        }
        try await row.save(on: db)
        return row
    }
}
