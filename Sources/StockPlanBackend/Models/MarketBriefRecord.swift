import Fluent
import Foundation
import Vapor

/// One generated brief in one language. `payload` is the JSON-encoded
/// `MarketBriefResponse`, served as stored. Unique per
/// (trading_date, slot, language), which is also what keeps two replicas
/// from both writing a slot.
final class MarketBriefRecord: Model, @unchecked Sendable {
    static let schema = "market_briefs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "trading_date")
    var tradingDate: String

    @Field(key: "slot")
    var slot: String

    @Field(key: "language")
    var language: String

    @Field(key: "payload")
    var payload: String

    @Field(key: "model")
    var model: String

    @Field(key: "degraded")
    var degraded: Bool

    @Field(key: "generated_at")
    var generatedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tradingDate: String,
        slot: String,
        language: String,
        payload: String,
        model: String,
        degraded: Bool,
        generatedAt: Date
    ) {
        self.id = id
        self.tradingDate = tradingDate
        self.slot = slot
        self.language = language
        self.payload = payload
        self.model = model
        self.degraded = degraded
        self.generatedAt = generatedAt
    }
}
