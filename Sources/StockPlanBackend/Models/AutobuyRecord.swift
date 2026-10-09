import Fluent
import Foundation
import StockPlanShared
import Vapor

/// A recurring buy that funds terminal targets. `amount` is the monthly base
/// when the cadence is `percentOfContribution`.
final class AutobuyRecord: Model, @unchecked Sendable {
    static let schema = "autobuys"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @OptionalField(key: "ticker")
    var ticker: String?

    @Field(key: "label")
    var label: String

    @Field(key: "amount")
    var amount: Double

    @Field(key: "cadence")
    var cadence: String

    @OptionalField(key: "percent")
    var percent: Double?

    @Field(key: "active")
    var active: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        ticker: String?,
        label: String,
        amount: Double,
        cadence: AutobuyCadence,
        percent: Double?,
        active: Bool
    ) {
        self.id = id
        self.userId = userId
        self.ticker = ticker
        self.label = label
        self.amount = amount
        self.cadence = cadence.rawValue
        self.percent = percent
        self.active = active
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<AutobuyRecord> {
        AutobuyRecord.query(on: db).filter(\.$userId == userId)
    }

    var cadenceValue: AutobuyCadence {
        AutobuyCadence(rawValue: cadence) ?? .unknown
    }

    var monthlyEquivalent: Double? {
        AutobuyMath.monthlyEquivalent(amount: amount, cadence: cadenceValue, percent: percent)
    }

    func toResponse() -> AutobuyResponse {
        let iso = ISO8601DateFormatter()
        return AutobuyResponse(
            id: id?.uuidString ?? "",
            ticker: ticker,
            label: label,
            amount: amount,
            cadence: cadenceValue,
            percent: percent,
            active: active,
            monthlyEquivalent: monthlyEquivalent,
            createdAt: iso.string(from: createdAt ?? Date()),
            updatedAt: iso.string(from: updatedAt ?? createdAt ?? Date())
        )
    }
}
