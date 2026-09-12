import Fluent
import FluentSQL

struct CreatePortfolioSimulationTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PortfolioSimulationRecord.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("mode", .string, .required)
            // A cloned simulation outlives the portfolio it was seeded from: the
            // weights stay meaningful even once the source is gone.
            .field("source_portfolio_id", .uuid, .references(PortfolioList.schema, "id", onDelete: .setNull))
            .field("name", .string, .required)
            .field("base_currency", .string, .required)
            .field("target_capital", .double, .required)
            .field("fractional_shares_enabled", .bool, .required)
            .field("quantity_increment", .double, .required)
            .field("minimum_trade_amount", .double, .required)
            .field("flat_fee", .double, .required)
            .field("variable_fee_bps", .int, .required)
            .field("revision", .int, .required)
            .field("share_slug", .string)
            .field("share_enabled", .bool, .required)
            .field("share_show_capital", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "share_slug")
            .create()

        try await database.schema(PortfolioSimulationLegRecord.schema)
            .id()
            .field(
                "simulation_id",
                .uuid,
                .required,
                .references(PortfolioSimulationRecord.schema, "id", onDelete: .cascade)
            )
            .field("symbol", .string, .required)
            .field("display_name", .string)
            .field("target_bps", .int, .required)
            .field("sort_order", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "simulation_id", "symbol")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.create(index: "portfolio_simulations_user_updated_idx")
                .on(PortfolioSimulationRecord.schema)
                .column("user_id")
                .column("updated_at")
                .run()
            // The public share route looks a simulation up by slug alone, then
            // checks share_enabled separately so the query cannot become an
            // existence oracle.
            try await sql.create(index: "portfolio_simulations_share_slug_idx")
                .on(PortfolioSimulationRecord.schema)
                .column("share_slug")
                .run()
            try await sql.create(index: "portfolio_simulation_legs_simulation_idx")
                .on(PortfolioSimulationLegRecord.schema)
                .column("simulation_id")
                .column("sort_order")
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PortfolioSimulationLegRecord.schema).delete()
        try await database.schema(PortfolioSimulationRecord.schema).delete()
    }
}
