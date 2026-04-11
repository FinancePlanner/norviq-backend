import Fluent
import FluentSQL
import SQLKit

private struct ColumnTypeInfo: Decodable {
    let dataType: String
    let udtName: String
}

struct ConvertBudgetPillarEnumToString: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await convertColumnIfNeeded(table: "budget_plan_items", column: "pillar", on: sql)
        try await convertColumnIfNeeded(table: "expenses", column: "pillar", on: sql)

        try await sql.raw("DROP TYPE IF EXISTS budget_pillar").run()
    }

    func revert(on database: any Database) async throws {
        // Irreversible without potentially lossy value mapping from custom pillars back to enum cases.
    }

    private func convertColumnIfNeeded(
        table: String,
        column: String,
        on sql: any SQLDatabase
    ) async throws {
        let info = try await sql.raw("""
            SELECT data_type AS "dataType", udt_name AS "udtName"
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = \(bind: table)
              AND column_name = \(bind: column)
            LIMIT 1
            """)
            .first(decoding: ColumnTypeInfo.self)

        guard let info else { return }
        if info.udtName == "budget_pillar" {
            try await sql.raw(
                "ALTER TABLE \(unsafeRaw: table) ALTER COLUMN \(unsafeRaw: column) TYPE TEXT USING \(unsafeRaw: column)::text"
            ).run()
        }
    }
}
