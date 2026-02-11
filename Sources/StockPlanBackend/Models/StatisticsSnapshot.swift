import Fluent
import Vapor
import Foundation

enum StatisticsKind: String, Codable, CaseIterable, Sendable {
    case importedStocks = "imported_stocks"
    case watchlist = "watchlist"
    case looklist = "looklist"
    case market = "market"
}

final class StatisticsSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "statistics_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "kind")
    var kind: String

    @Field(key: "as_of_date")
    var asOfDate: Date

    @Field(key: "generated_at")
    var generatedAt: Date

    @Field(key: "payload")
    var payload: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        kind: StatisticsKind,
        asOfDate: Date,
        generatedAt: Date,
        payload: String
    ) {
        self.id = id
        self.userId = userId
        self.kind = kind.rawValue
        self.asOfDate = asOfDate
        self.generatedAt = generatedAt
        self.payload = payload
    }
}
