import Fluent
import Foundation
import Vapor

final class AllocationModelRecord: Model, Content, @unchecked Sendable {
    static let schema = "allocation_models"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "created_by_user_id") var createdByUserId: UUID
    @Field(key: "name") var name: String
    @Field(key: "grouping_mode") var groupingMode: String
    @Field(key: "is_active") var isActive: Bool
    @Field(key: "revision") var revision: Int
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "default_target_threshold_bps") var defaultTargetThresholdBasisPoints: Int
    @Field(key: "total_threshold_bps") var totalThresholdBasisPoints: Int
    @Field(key: "fractional_shares_enabled") var fractionalSharesEnabled: Bool
    @Field(key: "quantity_increment") var quantityIncrement: Double
    @Field(key: "minimum_trade_amount") var minimumTradeAmount: Double
    @Field(key: "flat_fee") var flatFee: Double
    @Field(key: "variable_fee_bps") var variableFeeBasisPoints: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        portfolioId: UUID,
        createdByUserId: UUID,
        name: String,
        groupingMode: String,
        isActive: Bool,
        revision: Int = 1,
        baseCurrency: String,
        defaultTargetThresholdBasisPoints: Int,
        totalThresholdBasisPoints: Int,
        fractionalSharesEnabled: Bool,
        quantityIncrement: Double,
        minimumTradeAmount: Double,
        flatFee: Double,
        variableFeeBasisPoints: Int
    ) {
        self.id = id
        self.portfolioId = portfolioId
        self.createdByUserId = createdByUserId
        self.name = name
        self.groupingMode = groupingMode
        self.isActive = isActive
        self.revision = revision
        self.baseCurrency = baseCurrency
        self.defaultTargetThresholdBasisPoints = defaultTargetThresholdBasisPoints
        self.totalThresholdBasisPoints = totalThresholdBasisPoints
        self.fractionalSharesEnabled = fractionalSharesEnabled
        self.quantityIncrement = quantityIncrement
        self.minimumTradeAmount = minimumTradeAmount
        self.flatFee = flatFee
        self.variableFeeBasisPoints = variableFeeBasisPoints
    }
}

final class AllocationBucketRecord: Model, Content, @unchecked Sendable {
    static let schema = "allocation_buckets"

    @ID(key: .id) var id: UUID?
    @Field(key: "model_id") var modelId: UUID
    @Field(key: "name") var name: String
    @Field(key: "target_bps") var targetBasisPoints: Int
    @OptionalField(key: "alert_threshold_bps") var alertThresholdBasisPoints: Int?
    @OptionalField(key: "sector_key") var sectorKey: String?
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    init(
        id: UUID? = nil,
        modelId: UUID,
        name: String,
        targetBasisPoints: Int,
        alertThresholdBasisPoints: Int?,
        sectorKey: String?,
        sortOrder: Int
    ) {
        self.id = id
        self.modelId = modelId
        self.name = name
        self.targetBasisPoints = targetBasisPoints
        self.alertThresholdBasisPoints = alertThresholdBasisPoints
        self.sectorKey = sectorKey
        self.sortOrder = sortOrder
    }
}

final class AllocationLeafRecord: Model, Content, @unchecked Sendable {
    static let schema = "allocation_leaves"

    @ID(key: .id) var id: UUID?
    @Field(key: "model_id") var modelId: UUID
    @Field(key: "bucket_id") var bucketId: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "symbol") var symbol: String?
    @Field(key: "name") var name: String
    @Field(key: "target_bps") var targetBasisPoints: Int
    @OptionalField(key: "alert_threshold_bps") var alertThresholdBasisPoints: Int?
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    init(
        id: UUID? = nil,
        modelId: UUID,
        bucketId: UUID,
        kind: String,
        symbol: String?,
        name: String,
        targetBasisPoints: Int,
        alertThresholdBasisPoints: Int?,
        sortOrder: Int
    ) {
        self.id = id
        self.modelId = modelId
        self.bucketId = bucketId
        self.kind = kind
        self.symbol = symbol
        self.name = name
        self.targetBasisPoints = targetBasisPoints
        self.alertThresholdBasisPoints = alertThresholdBasisPoints
        self.sortOrder = sortOrder
    }
}

final class RebalancePlanRecord: Model, Content, @unchecked Sendable {
    static let schema = "rebalance_plans"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "model_id") var modelId: UUID
    @Field(key: "created_by_user_id") var createdByUserId: UUID
    @Field(key: "model_revision") var modelRevision: Int
    @OptionalField(key: "name") var name: String?
    @Field(key: "status") var status: String
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "drift_before_bps") var driftBeforeBasisPoints: Int
    @Field(key: "drift_after_bps") var driftAfterBasisPoints: Int
    @Field(key: "total_value") var totalValue: Double
    @Field(key: "estimated_fees") var estimatedFees: Double
    @Field(key: "estimated_realized_gain_loss") var estimatedRealizedGainLoss: Double
    @Field(key: "simulation_json") var simulationJSON: String
    @OptionalField(key: "completion_note") var completionNote: String?
    @OptionalField(key: "exported_at") var exportedAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?
    @OptionalField(key: "cancelled_at") var cancelledAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class RebalancingAlertRecord: Model, Content, @unchecked Sendable {
    static let schema = "rebalancing_alerts"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "model_id") var modelId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "scope_id") var scopeId: String
    @Field(key: "scope_name") var scopeName: String
    @Field(key: "drift_bps") var driftBasisPoints: Int
    @Field(key: "threshold_bps") var thresholdBasisPoints: Int
    @Field(key: "status") var status: String
    @OptionalField(key: "active_scope_key") var activeScopeKey: String?
    @Field(key: "triggered_at") var triggeredAt: Date
    @OptionalField(key: "acknowledged_at") var acknowledgedAt: Date?
    @OptionalField(key: "resolved_at") var resolvedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class RebalancingNotificationPreferenceRecord: Model, Content, @unchecked Sendable {
    static let schema = "rebalancing_notification_preferences"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "push_enabled") var pushEnabled: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(portfolioId: UUID, userId: UUID, pushEnabled: Bool) {
        self.portfolioId = portfolioId
        self.userId = userId
        self.pushEnabled = pushEnabled
    }
}
