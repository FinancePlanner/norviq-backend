import Fluent
import Foundation
import Vapor

/// A saved planning scenario - "Base", "Lean FIRE", "Keep rent".
///
/// User-scoped rather than portfolio-scoped, unlike `RetirementPlanRecord`. A plan about when
/// someone can stop working belongs to the person, not to one of their portfolios.
///
/// The body is stored as a JSON string, following `RetirementPlanRecord.inputJson` and
/// `WealthAutomationCoding`. That keeps the shape free to grow without a migration per field,
/// at the cost of it being opaque to SQL - which is acceptable here because scenarios are only
/// ever read back whole, by their owner.
final class PlanningScenarioRecord: Model, @unchecked Sendable {
    static let schema = "planning_scenarios"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "name")
    var name: String

    @Field(key: "kind")
    var kind: String

    @Field(key: "is_default")
    var isDefault: Bool

    @Field(key: "input_json")
    var inputJson: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        name: String,
        kind: String,
        isDefault: Bool,
        inputJson: String
    ) {
        self.id = id
        $user.id = userId
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
        self.inputJson = inputJson
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<PlanningScenarioRecord> {
        query(on: db).filter(\.$user.$id == userId)
    }
}
