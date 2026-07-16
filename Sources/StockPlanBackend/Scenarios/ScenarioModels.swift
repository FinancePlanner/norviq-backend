import Fluent
import Foundation
import Vapor

enum ScenarioJSONValue: Content, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ScenarioJSONValue])
    case object([String: ScenarioJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ScenarioJSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: ScenarioJSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var number: Double? {
        if case let .number(value) = self {
            value
        } else {
            nil
        }
    }

    var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    var array: [ScenarioJSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    var object: [String: ScenarioJSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }
}

struct ScenarioJSON: Content, Equatable, Sendable {
    var values: [String: ScenarioJSONValue]
    init(_ values: [String: ScenarioJSONValue] = [:]) {
        self.values = values
    }
}

final class HoldingRiskProfileModel: Model, Content, @unchecked Sendable {
    static let schema = "holding_risk_profiles"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "holding_id") var holdingId: UUID
    @Field(key: "asset_category") var assetCategory: String
    @OptionalField(key: "sector") var sector: String?
    @OptionalField(key: "region") var region: String?
    @OptionalField(key: "benchmark_proxy") var benchmarkProxy: String?
    @OptionalField(key: "manual_value") var manualValue: Double?
    @OptionalField(key: "duration") var duration: Double?
    @OptionalField(key: "convexity") var convexity: Double?
    @Field(key: "factor_overrides") var factorOverrides: ScenarioJSON
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(userId: UUID, holdingId: UUID, assetCategory: String) {
        self.userId = userId; self.holdingId = holdingId; self.assetCategory = assetCategory
        factorOverrides = ScenarioJSON()
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<HoldingRiskProfileModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

final class FinancialGoalModel: Model, Content, @unchecked Sendable {
    static let schema = "financial_goals"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @Field(key: "name") var name: String
    @Field(key: "goal_type") var goalType: String
    @Field(key: "target_amount") var targetAmount: Double
    @Field(key: "target_date") var targetDate: Date
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "starting_capital") var startingCapital: Double
    @Field(key: "monthly_contribution") var monthlyContribution: Double
    @Field(key: "annual_contribution_growth") var annualContributionGrowth: Double
    @Field(key: "inflation_assumption") var inflationAssumption: Double
    @Field(key: "risk_profile") var riskProfile: String
    @Field(key: "expected_annual_return") var expectedAnnualReturn: Double
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(id: UUID? = nil, userId: UUID, portfolioListId: UUID, name: String,
         goalType: String = "custom", targetAmount: Double, targetDate: Date, baseCurrency: String,
         startingCapital: Double = 0,
         monthlyContribution: Double, annualContributionGrowth: Double,
         inflationAssumption: Double, riskProfile: String = "moderate",
         expectedAnnualReturn: Double = 0.06, status: String = "active")
    {
        self.id = id; self.userId = userId; self.portfolioListId = portfolioListId; self.name = name
        self.goalType = goalType
        self.targetAmount = targetAmount; self.targetDate = targetDate; self.baseCurrency = baseCurrency
        self.startingCapital = startingCapital
        self.monthlyContribution = monthlyContribution; self.annualContributionGrowth = annualContributionGrowth
        self.inflationAssumption = inflationAssumption
        self.riskProfile = riskProfile; self.expectedAnnualReturn = expectedAnnualReturn; self.status = status
    }
}

final class ScenarioDefinitionModel: Model, Content, @unchecked Sendable {
    static let schema = "scenario_definitions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @OptionalField(key: "financial_goal_id") var financialGoalId: UUID?
    @Field(key: "name") var name: String
    @Field(key: "kind") var kind: String
    @Field(key: "configuration") var configuration: ScenarioJSON
    @Field(key: "is_saved") var isSaved: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(userId: UUID, portfolioListId: UUID, financialGoalId: UUID?, name: String,
         kind: String, configuration: ScenarioJSON, isSaved: Bool)
    {
        self.userId = userId; self.portfolioListId = portfolioListId; self.financialGoalId = financialGoalId
        self.name = name; self.kind = kind; self.configuration = configuration; self.isSaved = isSaved
    }
}

final class ScenarioSnapshotModel: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_scenario_snapshots"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "portfolio_list_id") var portfolioListId: UUID
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "valuation_timestamp") var valuationTimestamp: Date
    @Field(key: "payload") var payload: ScenarioJSON
    @Field(key: "warnings") var warnings: ScenarioJSON
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(userId: UUID, portfolioListId: UUID, baseCurrency: String, valuationTimestamp: Date,
         payload: ScenarioJSON, warnings: ScenarioJSON)
    {
        self.userId = userId; self.portfolioListId = portfolioListId; self.baseCurrency = baseCurrency
        self.valuationTimestamp = valuationTimestamp; self.payload = payload; self.warnings = warnings
    }
}

final class ScenarioRunModel: Model, Content, @unchecked Sendable {
    static let schema = "scenario_runs"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Parent(key: "scenario_id") var scenario: ScenarioDefinitionModel
    @Parent(key: "snapshot_id") var snapshot: ScenarioSnapshotModel
    @Field(key: "state") var state: String
    @Field(key: "progress") var progress: Double
    @Field(key: "seed") var seed: String
    @Field(key: "deduplication_hash") var deduplicationHash: String
    @Field(key: "engine_version") var engineVersion: String
    @Field(key: "catalog_version") var catalogVersion: String
    @OptionalField(key: "result") var result: ScenarioJSON?
    @OptionalField(key: "error_message") var errorMessage: String?
    @OptionalField(key: "lease_owner") var leaseOwner: String?
    @OptionalField(key: "lease_expires_at") var leaseExpiresAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?
    @OptionalField(key: "expires_at") var expiresAt: Date?

    init() {}
    init(userId: UUID, scenarioId: UUID, snapshotId: UUID, seed: UInt64, deduplicationHash: String,
         expiresAt: Date?)
    {
        self.userId = userId; $scenario.id = scenarioId; $snapshot.id = snapshotId
        state = "queued"; progress = 0; self.seed = String(seed); self.deduplicationHash = deduplicationHash
        engineVersion = ScenarioEngine.version; catalogVersion = ScenarioCatalog.version; self.expiresAt = expiresAt
    }
}

extension FinancialGoalModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<FinancialGoalModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

extension ScenarioDefinitionModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<ScenarioDefinitionModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

extension ScenarioSnapshotModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<ScenarioSnapshotModel> {
        query(on: db).filter(\.$userId == userId)
    }
}

extension ScenarioRunModel {
    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<ScenarioRunModel> {
        query(on: db).filter(\.$userId == userId)
    }
}
