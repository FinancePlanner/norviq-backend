import Fluent
import Foundation
import Vapor

final class NetWorthSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "net_worth_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "dedupe_key")
    var dedupeKey: String

    @Field(key: "total_value")
    var totalValue: Double?

    @Field(key: "currency")
    var currency: String

    @Field(key: "captured_at")
    var capturedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        dedupeKey: String,
        totalValue: Double?,
        currency: String = "USD",
        capturedAt: Date
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.totalValue = totalValue
        self.currency = currency
        self.capturedAt = capturedAt
    }
}
