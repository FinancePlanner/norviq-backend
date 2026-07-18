import Fluent

struct ExpandTaxOptimizationV2: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TaxScenario.schema)
            .field("kind", .string, .required, .sql(.default("harvest")))
            .update()

        try await database.schema(TaxActionPlan.schema)
            .field("kind", .string, .required, .sql(.default("harvest")))
            .field("executed_at", .datetime)
            .field("confirmation_note", .string)
            .update()

        try await database.schema(TaxActionLegRecord.schema)
            .id()
            .field("action_plan_id", .uuid, .required, .references(TaxActionPlan.schema, "id", onDelete: .cascade))
            .field("account_id", .uuid, .required, .references(Account.schema, "id", onDelete: .cascade))
            .field("portfolio_id", .uuid, .references(PortfolioList.schema, "id", onDelete: .setNull))
            .field("instrument_id", .uuid, .required, .references(Instrument.schema, "id", onDelete: .restrict))
            .field("symbol", .string, .required)
            .field("side", .string, .required)
            .field("quantity", .double)
            .field("notional", .double, .required)
            .field("currency", .string, .required)
            .field("lot_ids_json", .string, .required)
            .field("status", .string, .required)
            .field("matched_transaction_id", .uuid, .references(Transaction.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema(TaxActionRebalancingPlanLink.schema)
            .id()
            .field("action_plan_id", .uuid, .required, .references(TaxActionPlan.schema, "id", onDelete: .cascade))
            .field("rebalancing_plan_id", .uuid, .required, .references(RebalancePlanRecord.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "action_plan_id", "rebalancing_plan_id")
            .create()

        try await database.schema(TaxOpportunityDecision.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("tax_year", .int, .required)
            .field("opportunity_id", .string, .required)
            .field("status", .string, .required)
            .field("estimated_benefit", .double, .required)
            .field("currency", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "tax_year", "opportunity_id")
            .create()

        try await database.schema(TaxRestrictionWindow.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("action_leg_id", .uuid, .required, .references(TaxActionLegRecord.schema, "id", onDelete: .cascade))
            .field("jurisdiction", .string, .required)
            .field("tax_identity_key", .string, .required)
            .field("starts_at", .datetime, .required)
            .field("ends_at", .datetime, .required)
            .field("status", .string, .required)
            .field("violating_transaction_id", .uuid, .references(Transaction.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "action_leg_id")
            .create()

        try await database.createIndex(
            on: TaxActionLegRecord.schema,
            columns: ["account_id", "instrument_id", "side", "status"]
        )
        try await database.createIndex(
            on: TaxRestrictionWindow.schema,
            columns: ["user_id", "tax_identity_key", "ends_at", "status"]
        )
    }

    func revert(on database: any Database) async throws {
        try await database.schema(TaxRestrictionWindow.schema).delete()
        try await database.schema(TaxOpportunityDecision.schema).delete()
        try await database.schema(TaxActionRebalancingPlanLink.schema).delete()
        try await database.schema(TaxActionLegRecord.schema).delete()
        try await database.schema(TaxActionPlan.schema)
            .deleteField("confirmation_note")
            .deleteField("executed_at")
            .deleteField("kind")
            .update()
        try await database.schema(TaxScenario.schema)
            .deleteField("kind")
            .update()
    }
}
