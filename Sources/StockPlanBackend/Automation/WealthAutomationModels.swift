import Fluent
import Foundation
import StockPlanShared
import Vapor

final class NetWorthForecastModel: Model, @unchecked Sendable {
    static let schema = "net_worth_forecasts"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @Field(key: "name") var name: String
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "horizon_months") var horizonMonths: Int
    @Field(key: "include_cash") var includeCash: Bool
    @Field(key: "include_crypto") var includeCrypto: Bool
    @Field(key: "annual_income_growth") var annualIncomeGrowth: Double
    @Field(key: "annual_spending_growth") var annualSpendingGrowth: Double
    @Field(key: "inflation_assumption") var inflationAssumption: Double
    @OptionalField(key: "monthly_income_override") var monthlyIncomeOverride: Double?
    @OptionalField(key: "monthly_spending_override") var monthlySpendingOverride: Double?
    @OptionalField(key: "target_amount") var targetAmount: Double?
    @Field(key: "path_count") var pathCount: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, portfolioListId: UUID, input: NetWorthForecastUpsertRequest) {
        self.userId = userId
        self.portfolioListId = portfolioListId
        apply(input)
    }

    func apply(_ input: NetWorthForecastUpsertRequest) {
        name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        baseCurrency = input.baseCurrency.uppercased()
        horizonMonths = input.horizonMonths
        includeCash = input.includeCash
        includeCrypto = input.includeCrypto
        annualIncomeGrowth = input.annualIncomeGrowth
        annualSpendingGrowth = input.annualSpendingGrowth
        inflationAssumption = input.inflationAssumption
        monthlyIncomeOverride = input.monthlyIncomeOverride
        monthlySpendingOverride = input.monthlySpendingOverride
        targetAmount = input.targetAmount
        pathCount = input.pathCount
    }
}

final class NetWorthForecastRunModel: Model, @unchecked Sendable {
    static let schema = "net_worth_forecast_runs"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Parent(key: "forecast_id") var forecast: NetWorthForecastModel
    @Field(key: "status") var status: String
    @Field(key: "starting_value") var startingValue: Double
    @Field(key: "assumptions") var assumptions: ScenarioJSON
    @Field(key: "timeline") var timeline: ScenarioJSON
    @OptionalField(key: "target_probability") var targetProbability: Double?
    @Field(key: "seed") var seed: String
    @OptionalField(key: "failure_reason") var failureReason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?

    init() {}
}

final class WatchlistScreenModel: Model, @unchecked Sendable {
    static let schema = "watchlist_screens"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "name") var name: String
    @Field(key: "watchlist_list_ids") var watchlistListIds: [UUID]
    @Field(key: "logical_operator") var logicalOperator: String
    @Field(key: "groups") var groups: ScenarioJSON
    @Field(key: "alerts_enabled") var alertsEnabled: Bool
    @OptionalField(key: "last_evaluated_at") var lastEvaluatedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class WatchlistScreenEvaluationModel: Model, @unchecked Sendable {
    static let schema = "watchlist_screen_evaluations"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Parent(key: "screen_id") var screen: WatchlistScreenModel
    @Field(key: "symbol_count") var symbolCount: Int
    @Field(key: "match_symbols") var matchSymbols: [String]
    @Field(key: "result") var result: ScenarioJSON
    @Field(key: "is_alert_baseline") var isAlertBaseline: Bool
    @Timestamp(key: "evaluated_at", on: .create) var evaluatedAt: Date?

    init() {}
}

final class RebalancingPolicyModel: Model, @unchecked Sendable {
    static let schema = "rebalancing_policies"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @Field(key: "cadence") var cadence: String
    @OptionalField(key: "drift_threshold") var driftThreshold: Double?
    @Field(key: "targets") var targets: ScenarioJSON
    @Field(key: "enabled") var enabled: Bool
    @OptionalField(key: "last_confirmed_at") var lastConfirmedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class RebalanceEventModel: Model, @unchecked Sendable {
    static let schema = "rebalance_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Parent(key: "policy_id") var policy: RebalancingPolicyModel
    @Field(key: "status") var status: String
    @Field(key: "preview") var preview: ScenarioJSON
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "confirmed_at") var confirmedAt: Date?

    init() {}
}

final class NotificationEventModel: Model, @unchecked Sendable {
    static let schema = "notification_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "deduplication_key") var deduplicationKey: String
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @OptionalField(key: "deep_link") var deepLink: String?
    @Field(key: "payload") var payload: [String: String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "read_at") var readAt: Date?

    init() {}

    init(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String? = nil,
        payload: [String: String] = [:]
    ) {
        self.userId = userId
        self.kind = kind.rawValue
        self.deduplicationKey = deduplicationKey
        self.title = title
        self.body = body
        self.deepLink = deepLink
        self.payload = payload
    }
}

final class NotificationDeliveryModel: Model, @unchecked Sendable {
    static let schema = "notification_deliveries"

    @ID(key: .id) var id: UUID?
    @Parent(key: "event_id") var event: NotificationEventModel
    @Field(key: "channel") var channel: String
    @Field(key: "status") var status: String
    @Field(key: "attempt_count") var attemptCount: Int
    @OptionalField(key: "last_error") var lastError: String?
    @OptionalField(key: "next_attempt_at") var nextAttemptAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class AutomationJobLeaseModel: Model, @unchecked Sendable {
    static let schema = "automation_job_leases"

    @ID(custom: "name", generatedBy: .user) var id: String?
    @Field(key: "owner") var owner: String
    @Field(key: "locked_until") var lockedUntil: Date
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

extension NetWorthForecastModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<NetWorthForecastModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

extension WatchlistScreenModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<WatchlistScreenModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

extension RebalancingPolicyModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<RebalancingPolicyModel> {
        query(on: db).filter(\.$userId == userId)
    }
}
