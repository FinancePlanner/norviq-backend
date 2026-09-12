import Fluent
import Foundation
import Vapor

/// A hypothetical portfolio the user is pricing. Deliberately its own entity rather
/// than a `PortfolioList`, so a simulation can never leak into net worth, tax, or
/// broker-sync queries. Scoped to a user, not a portfolio: a from-scratch simulation
/// has no portfolio to belong to.
final class PortfolioSimulationRecord: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_simulations"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "mode") var mode: String
    @OptionalField(key: "source_portfolio_id") var sourcePortfolioId: UUID?
    @Field(key: "name") var name: String
    @Field(key: "base_currency") var baseCurrency: String
    @Field(key: "target_capital") var targetCapital: Double
    @Field(key: "fractional_shares_enabled") var fractionalSharesEnabled: Bool
    @Field(key: "quantity_increment") var quantityIncrement: Double
    @Field(key: "minimum_trade_amount") var minimumTradeAmount: Double
    @Field(key: "flat_fee") var flatFee: Double
    @Field(key: "variable_fee_bps") var variableFeeBasisPoints: Int
    @Field(key: "revision") var revision: Int
    @OptionalField(key: "share_slug") var shareSlug: String?
    @Field(key: "share_enabled") var shareEnabled: Bool
    @Field(key: "share_show_capital") var shareShowCapital: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        mode: String,
        sourcePortfolioId: UUID? = nil,
        name: String,
        baseCurrency: String,
        targetCapital: Double,
        fractionalSharesEnabled: Bool,
        quantityIncrement: Double,
        minimumTradeAmount: Double,
        flatFee: Double,
        variableFeeBasisPoints: Int,
        revision: Int = 1,
        shareSlug: String? = nil,
        shareEnabled: Bool = false,
        shareShowCapital: Bool = true
    ) {
        self.id = id
        self.userId = userId
        self.mode = mode
        self.sourcePortfolioId = sourcePortfolioId
        self.name = name
        self.baseCurrency = baseCurrency
        self.targetCapital = targetCapital
        self.fractionalSharesEnabled = fractionalSharesEnabled
        self.quantityIncrement = quantityIncrement
        self.minimumTradeAmount = minimumTradeAmount
        self.flatFee = flatFee
        self.variableFeeBasisPoints = variableFeeBasisPoints
        self.revision = revision
        self.shareSlug = shareSlug
        self.shareEnabled = shareEnabled
        self.shareShowCapital = shareShowCapital
    }
}

final class PortfolioSimulationLegRecord: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_simulation_legs"

    @ID(key: .id) var id: UUID?
    @Field(key: "simulation_id") var simulationId: UUID
    @Field(key: "symbol") var symbol: String
    @OptionalField(key: "display_name") var displayName: String?
    @Field(key: "target_bps") var targetBasisPoints: Int
    @Field(key: "sort_order") var sortOrder: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        simulationId: UUID,
        symbol: String,
        displayName: String? = nil,
        targetBasisPoints: Int,
        sortOrder: Int
    ) {
        self.id = id
        self.simulationId = simulationId
        self.symbol = symbol
        self.displayName = displayName
        self.targetBasisPoints = targetBasisPoints
        self.sortOrder = sortOrder
    }
}
