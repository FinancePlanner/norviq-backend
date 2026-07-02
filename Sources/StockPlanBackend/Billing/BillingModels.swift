import Fluent
import Foundation
import Vapor

final class Subscription: Model, Content, @unchecked Sendable {
    static let schema = "subscriptions"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "provider") var provider: String
    @OptionalField(key: "store") var store: String?
    @Field(key: "provider_customer_id") var providerCustomerId: String
    @Field(key: "provider_original_transaction_id") var providerOriginalTransactionId: String
    @Field(key: "product_id") var productId: String
    @Field(key: "plan") var plan: String
    @Field(key: "status") var status: String
    @OptionalField(key: "pending_product_id") var pendingProductId: String?
    @OptionalField(key: "pending_plan") var pendingPlan: String?
    @OptionalField(key: "pending_plan_effective_at") var pendingPlanEffectiveAt: Date?
    @OptionalField(key: "period_started_at") var periodStartedAt: Date?
    @OptionalField(key: "period_ends_at") var periodEndsAt: Date?
    @OptionalField(key: "trial_ends_at") var trialEndsAt: Date?
    @OptionalField(key: "grace_period_ends_at") var gracePeriodEndsAt: Date?
    @OptionalField(key: "cancelled_at") var cancelledAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        provider: String,
        store: String? = nil,
        providerCustomerId: String,
        providerOriginalTransactionId: String,
        productId: String,
        plan: String,
        status: String,
        pendingProductId: String? = nil,
        pendingPlan: String? = nil,
        pendingPlanEffectiveAt: Date? = nil,
        periodStartedAt: Date? = nil,
        periodEndsAt: Date? = nil,
        trialEndsAt: Date? = nil,
        gracePeriodEndsAt: Date? = nil,
        cancelledAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.provider = provider
        self.store = store
        self.providerCustomerId = providerCustomerId
        self.providerOriginalTransactionId = providerOriginalTransactionId
        self.productId = productId
        self.plan = plan
        self.status = status
        self.pendingProductId = pendingProductId
        self.pendingPlan = pendingPlan
        self.pendingPlanEffectiveAt = pendingPlanEffectiveAt
        self.periodStartedAt = periodStartedAt
        self.periodEndsAt = periodEndsAt
        self.trialEndsAt = trialEndsAt
        self.gracePeriodEndsAt = gracePeriodEndsAt
        self.cancelledAt = cancelledAt
    }
}

final class Entitlement: Model, Content, @unchecked Sendable {
    static let schema = "entitlements"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "level") var level: String
    @OptionalField(key: "subscription_id") var subscriptionId: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, level: String, subscriptionId: UUID? = nil) {
        self.id = id
        self.userId = userId
        self.level = level
        self.subscriptionId = subscriptionId
    }
}

final class BillingEvent: Model, Content, @unchecked Sendable {
    static let schema = "billing_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "provider_event_id") var providerEventId: String
    @Field(key: "provider") var provider: String
    @Field(key: "event_type") var eventType: String
    @OptionalField(key: "user_id") var userId: UUID?
    @Field(key: "raw_payload") var rawPayload: String
    @Field(key: "processed_at") var processedAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        providerEventId: String,
        provider: String,
        eventType: String,
        userId: UUID?,
        rawPayload: String,
        processedAt: Date
    ) {
        self.id = id
        self.providerEventId = providerEventId
        self.provider = provider
        self.eventType = eventType
        self.userId = userId
        self.rawPayload = rawPayload
        self.processedAt = processedAt
    }
}

final class UsageCounter: Model, Content, @unchecked Sendable {
    static let schema = "usage_counters"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "period_start") var periodStart: Date
    @Field(key: "holding_count") var holdingCount: Int
    @Field(key: "watchlist_item_count") var watchlistItemCount: Int
    @Field(key: "csv_import_count") var csvImportCount: Int
    @Field(key: "target_alert_count") var targetAlertCount: Int
    @Field(key: "report_generation_count") var reportGenerationCount: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, periodStart: Date) {
        self.id = id
        self.userId = userId
        self.periodStart = periodStart
        holdingCount = 0
        watchlistItemCount = 0
        csvImportCount = 0
        targetAlertCount = 0
        reportGenerationCount = 0
    }
}
