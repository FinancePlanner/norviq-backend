import Fluent
import Foundation

final class LotDisposal: Model, @unchecked Sendable {
    static let schema = "lot_disposals"

    @ID(key: .id) var id: UUID?
    @Field(key: "lot_id") var lotId: UUID
    @Field(key: "transaction_id") var transactionId: UUID
    @Field(key: "quantity") var quantity: Double
    @Field(key: "proceeds") var proceeds: Double
    @Field(key: "cost_basis") var costBasis: Double
    @Field(key: "realized_pnl") var realizedPnl: Double
    @Field(key: "holding_period") var holdingPeriod: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class LotAdjustment: Model, @unchecked Sendable {
    static let schema = "lot_adjustments"

    @ID(key: .id) var id: UUID?
    @Field(key: "lot_id") var lotId: UUID
    @OptionalField(key: "source_transaction_id") var sourceTransactionId: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "amount") var amount: Double
    @OptionalField(key: "quantity") var quantity: Double?
    @Field(key: "currency") var currency: String
    @Field(key: "effective_date") var effectiveDate: Date
    @OptionalField(key: "metadata_json") var metadataJSON: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class WashSaleMatch: Model, @unchecked Sendable {
    static let schema = "wash_sale_matches"

    @ID(key: .id) var id: UUID?
    @Field(key: "disposal_id") var disposalId: UUID
    @Field(key: "replacement_lot_id") var replacementLotId: UUID
    @Field(key: "matched_quantity") var matchedQuantity: Double
    @Field(key: "disallowed_loss") var disallowedLoss: Double
    @Field(key: "currency") var currency: String
    @Field(key: "is_permanent") var isPermanent: Bool
    @Field(key: "rule_version") var ruleVersion: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class TaxNotificationDelivery: Model, @unchecked Sendable {
    static let schema = "tax_notification_deliveries"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "opportunity_id") var opportunityId: String
    @Field(key: "instrument_id") var instrumentId: UUID
    @Field(key: "estimated_benefit") var estimatedBenefit: Double
    @Field(key: "currency") var currency: String
    @Field(key: "delivered_at") var deliveredAt: Date

    init() {}
}

final class TaxProfile: Model, @unchecked Sendable {
    static let schema = "tax_profiles"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "jurisdiction") var jurisdiction: String
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "filing_status") var filingStatus: String
    @Field(key: "reporting_currency") var reportingCurrency: String
    @Field(key: "profile_json") var profileJSON: String
    @Field(key: "is_complete") var isComplete: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxProjectionSnapshot: Model, @unchecked Sendable {
    static let schema = "tax_projection_snapshots"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "profile_id") var profileId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "jurisdiction") var jurisdiction: String
    @Field(key: "rule_version") var ruleVersion: String
    @Field(key: "status") var status: String
    @Field(key: "response_json") var responseJSON: String
    @Field(key: "input_hash") var inputHash: String
    @Field(key: "generated_at") var generatedAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class TaxScenario: Model, @unchecked Sendable {
    static let schema = "tax_scenarios"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "profile_id") var profileId: UUID
    @Field(key: "request_json") var requestJSON: String
    @Field(key: "response_json") var responseJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

final class TaxActionPlan: Model, @unchecked Sendable {
    static let schema = "tax_action_plans"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "scenario_id") var scenarioId: UUID
    @Field(key: "idempotency_key") var idempotencyKey: String
    @Field(key: "status") var status: String
    @Field(key: "response_json") var responseJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxNotificationPreference: Model, @unchecked Sendable {
    static let schema = "tax_notification_preferences"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "enabled") var enabled: Bool
    @OptionalField(key: "minimum_benefit") var minimumBenefit: Double?
    @Field(key: "cooldown_days") var cooldownDays: Int
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxReport: Model, @unchecked Sendable {
    static let schema = "tax_reports"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "kind") var kind: String
    @Field(key: "format") var format: String
    @Field(key: "status") var status: String
    @OptionalField(key: "attempt_count") var attemptCount: Int?
    @OptionalField(key: "next_attempt_at") var nextAttemptAt: Date?
    @OptionalField(key: "file_path") var filePath: String?
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxProjectionJob: Model, @unchecked Sendable {
    static let schema = "tax_projection_jobs"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @Field(key: "reason") var reason: String
    @Field(key: "idempotency_key") var idempotencyKey: String
    @Field(key: "status") var status: String
    @Field(key: "attempt_count") var attemptCount: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    @OptionalField(key: "last_error") var lastError: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxLossCarryforward: Model, @unchecked Sendable {
    static let schema = "tax_loss_carryforwards"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "jurisdiction") var jurisdiction: String
    @Field(key: "source_tax_year") var sourceTaxYear: Int
    @Field(key: "expires_after_tax_year") var expiresAfterTaxYear: Int
    @Field(key: "original_amount") var originalAmount: Double
    @Field(key: "remaining_amount") var remainingAmount: Double
    @Field(key: "currency") var currency: String
    @Field(key: "rule_version") var ruleVersion: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class TaxLossCarryforwardApplication: Model, @unchecked Sendable {
    static let schema = "tax_loss_carryforward_applications"

    @ID(key: .id) var id: UUID?
    @Field(key: "carryforward_id") var carryforwardId: UUID
    @Field(key: "target_tax_year") var targetTaxYear: Int
    @Field(key: "amount") var amount: Double
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
