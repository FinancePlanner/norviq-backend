import Fluent
import FluentSQL

/// One row per user: funnel position, the three guided-start latches, and the
/// card's dismissal. Contract: norviq-shared/docs/guided-start.md.
struct CreateOnboardingState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS onboarding_state (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
            funnel_step TEXT,
            funnel_completed_at TIMESTAMPTZ,
            first_holding_at TIMESTAMPTZ,
            first_budget_at TIMESTAMPTZ,
            first_goal_at TIMESTAMPTZ,
            guided_start_dismissed_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ
        )
        """).run()
        try await OnboardingBackfill.run(on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS onboarding_state").run()
    }
}

/// Every account that exists when this runs has finished its funnel and does
/// not get the card pushed at it; "Show me around" brings it back with real
/// progress. Rows that already exist are left alone. Crypto holdings do not
/// count toward `add_holding`, matching `AssetCategory.countsTowardAddHolding`.
enum OnboardingBackfill {
    static func run(on sql: any SQLDatabase) async throws {
        try await sql.raw("""
        INSERT INTO onboarding_state (id, user_id, first_holding_at, first_budget_at, first_goal_at,
                                      funnel_completed_at, guided_start_dismissed_at, created_at, updated_at)
        SELECT gen_random_uuid(), u.id,
               (SELECT min(s.created_at) FROM stocks s WHERE s.user_id = u.id AND s.category <> 'crypto'),
               (SELECT min(b.created_at) FROM budget_snapshots b WHERE b.user_id = u.id AND b.net_salary > 0),
               (SELECT min(g.created_at) FROM financial_goals g WHERE g.user_id = u.id),
               NOW(), NOW(), NOW(), NOW()
        FROM users u
        ON CONFLICT (user_id) DO NOTHING
        """).run()
    }
}
