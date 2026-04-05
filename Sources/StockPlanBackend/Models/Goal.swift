import Fluent
import Vapor
import Foundation

final class Goal: Model, Content, @unchecked Sendable {
    static let schema = "goals"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "title")
    var title: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(id: UUID? = nil, userId: UUID, title: String) {
        self.id = id
        self.userId = userId
        self.title = title
    }

    // MARK: - Active Record helpers (ownership-scoped)

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<Goal> {
        Goal.query(on: db).filter(\.$userId == userId)
    }

    static func create(title: String, userId: UUID, on db: any Database) async throws -> Goal {
        let goal = Goal(userId: userId, title: title)
        try await goal.save(on: db)
        return goal
    }

    static func find(_ id: UUID, userId: UUID, on db: any Database) async throws -> Goal? {
        try await Goal.owned(by: userId, on: db)
            .filter(\.$id == id)
            .first()
    }
}

struct CreateGoal: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("goals")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("goals").delete()
    }
}
