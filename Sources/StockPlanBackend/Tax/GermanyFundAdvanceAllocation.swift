import Fluent
import Foundation

final class GermanyFundAdvanceAllocation: Model, @unchecked Sendable {
    static let schema = "germany_fund_advance_allocations"

    @ID(key: .id) var id: UUID?
    @Field(key: "annual_holding_id") var annualHoldingId: UUID
    @Field(key: "disposal_id") var disposalId: UUID
    @Field(key: "quantity") var quantity: Double
    @Field(key: "gross_advance_amount") var grossAdvanceAmount: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(annualHoldingId: UUID, disposalId: UUID, quantity: Double, grossAdvanceAmount: Double) {
        self.annualHoldingId = annualHoldingId
        self.disposalId = disposalId
        self.quantity = quantity
        self.grossAdvanceAmount = grossAdvanceAmount
    }
}
