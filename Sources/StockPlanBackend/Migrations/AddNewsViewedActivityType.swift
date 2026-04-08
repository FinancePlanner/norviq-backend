import Fluent
import StockPlanShared

struct AddNewsViewedActivityType: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.enum("user_activity_type")
            .case("news_viewed")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.enum("user_activity_type")
            .deleteCase("news_viewed")
            .update()
    }
}
