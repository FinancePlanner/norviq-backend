import Fluent
import Foundation

final class GermanyFundAnnualHolding: Model, @unchecked Sendable {
    static let schema = "germany_fund_annual_holdings"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "instrument_id") var instrumentId: UUID
    @Field(key: "calculation_year") var calculationYear: Int
    @Field(key: "client_holding_id") var clientHoldingId: String
    @OptionalField(key: "lot_id") var lotId: UUID?
    @OptionalField(key: "quantity") var quantity: Double?
    @OptionalField(key: "remaining_quantity") var remainingQuantity: Double?
    @Field(key: "currency") var currency: String
    @Field(key: "beginning_market_value") var beginningMarketValue: Double
    @Field(key: "ending_market_value") var endingMarketValue: Double
    @Field(key: "distributions") var distributions: Double
    @OptionalField(key: "acquisition_month") var acquisitionMonth: Int?
    @Field(key: "fund_classification") var fundClassification: String
    @Field(key: "basis_rate") var basisRate: Double
    @Field(key: "gross_advance_lump_sum") var grossAdvanceLumpSum: Double
    @Field(key: "remaining_gross_advance") var remainingGrossAdvance: Double
    @Field(key: "taxable_advance_lump_sum") var taxableAdvanceLumpSum: Double
    @Field(key: "rule_version") var ruleVersion: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
