import Fluent
import Vapor
import Foundation

final class Lot: Model, Content, @unchecked Sendable {
    static let schema = "lots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    @Field(key: "instrument_id")
    var instrumentId: UUID

    @Field(key: "open_transaction_id")
    var openTransactionId: UUID?

    @Field(key: "close_transaction_id")
    var closeTransactionId: UUID?

    @Field(key: "open_date")
    var openDate: Date

    @Field(key: "close_date")
    var closeDate: Date?

    @Field(key: "open_quantity")
    var openQuantity: Double

    @Field(key: "remaining_quantity")
    var remainingQuantity: Double

    @Field(key: "open_price")
    var openPrice: Double

    @Field(key: "currency")
    var currency: String

    @Field(key: "realized_pnl")
    var realizedPnl: Double?

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        accountId: UUID,
        instrumentId: UUID,
        openTransactionId: UUID? = nil,
        closeTransactionId: UUID? = nil,
        openDate: Date,
        closeDate: Date? = nil,
        openQuantity: Double,
        remainingQuantity: Double,
        openPrice: Double,
        currency: String,
        realizedPnl: Double? = nil,
        status: String
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.openTransactionId = openTransactionId
        self.closeTransactionId = closeTransactionId
        self.openDate = openDate
        self.closeDate = closeDate
        self.openQuantity = openQuantity
        self.remainingQuantity = remainingQuantity
        self.openPrice = openPrice
        self.currency = currency
        self.realizedPnl = realizedPnl
        self.status = status
    }
}
