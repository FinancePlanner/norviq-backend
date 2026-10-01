import Fluent
import FluentSQL
import SQLKit

/// `AddAssetCategoryToStocks` created the Postgres `asset_category` type with
/// only stock/etf/crypto, while `AssetCategory` has eight cases. Saving a
/// holding as cash, bond, etc. failed with an invalid enum value.
struct ExtendAssetCategoryEnum: AsyncMigration {
    /// Frozen on purpose: a later case needs its own migration.
    static let addedCases = ["mutual_fund", "cash", "bond", "real_estate", "commodity"]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // IF NOT EXISTS keeps this re-runnable if a previous attempt stopped halfway.
        for value in Self.addedCases {
            try await sql.raw("ALTER TYPE asset_category ADD VALUE IF NOT EXISTS '\(unsafeRaw: value)'").run()
        }
    }

    func revert(on _: any Database) async throws {
        // Postgres cannot drop enum values.
    }
}
