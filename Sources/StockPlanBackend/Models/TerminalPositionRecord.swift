import Fluent
import Foundation
import StockPlanShared
import Vapor

/// One terminal scenario. Stores the user's assumptions only; every derived
/// number comes from `TerminalMath` at read time.
final class TerminalPositionRecord: Model, @unchecked Sendable {
    static let schema = "terminal_positions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "ticker")
    var ticker: String

    @OptionalField(key: "shares_outstanding")
    var sharesOutstanding: Double?

    @Field(key: "terminal_share_count")
    var terminalShareCount: Double

    @Field(key: "terminal_market_cap")
    var terminalMarketCap: Double

    @Field(key: "value_wanted")
    var valueWanted: Double

    @Field(key: "shares_owned")
    var sharesOwned: Double

    @OptionalField(key: "current_share_price")
    var currentSharePrice: Double?

    @OptionalField(key: "notes")
    var notes: String?

    @Field(key: "sort_order")
    var sortOrder: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        ticker: String,
        sharesOutstanding: Double?,
        terminalShareCount: Double,
        terminalMarketCap: Double,
        valueWanted: Double,
        sharesOwned: Double,
        currentSharePrice: Double?,
        notes: String?,
        sortOrder: Int
    ) {
        self.id = id
        self.userId = userId
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
        self.notes = notes
        self.sortOrder = sortOrder
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<TerminalPositionRecord> {
        TerminalPositionRecord.query(on: db).filter(\.$userId == userId)
    }

    func toResponse() -> TerminalPositionResponse {
        let evaluation = TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: terminalShareCount,
            terminalMarketCap: terminalMarketCap,
            valueWanted: valueWanted,
            sharesOwned: sharesOwned,
            currentSharePrice: currentSharePrice
        ))
        let result = try? evaluation.get()
        let scenarioError: String? = if case let .failure(error) = evaluation {
            error.rawValue
        } else {
            nil
        }
        let iso = ISO8601DateFormatter()
        return TerminalPositionResponse(
            id: id?.uuidString ?? "",
            ticker: ticker,
            sharesOutstanding: sharesOutstanding,
            terminalShareCount: terminalShareCount,
            terminalMarketCap: terminalMarketCap,
            valueWanted: valueWanted,
            sharesOwned: sharesOwned,
            currentSharePrice: currentSharePrice,
            notes: notes,
            sortOrder: sortOrder,
            terminalSharePrice: result?.terminalSharePrice,
            sharesNeeded: result?.sharesNeeded,
            capitalAtTodayPrice: result?.capitalAtTodayPrice,
            progress: result?.progress,
            sharesStillNeeded: result?.sharesStillNeeded,
            gapValueAtTerminal: result?.gapValueAtTerminal,
            scenarioError: scenarioError,
            createdAt: iso.string(from: createdAt ?? Date()),
            updatedAt: iso.string(from: updatedAt ?? createdAt ?? Date())
        )
    }
}
