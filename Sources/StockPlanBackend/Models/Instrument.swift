import Fluent
import Foundation
import Vapor

final class Instrument: Model, Content, @unchecked Sendable {
    static let schema = "instruments"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "conid")
    var conid: String

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "exchange")
    var exchange: String

    @OptionalField(key: "listing_exchange")
    var listingExchange: String?

    @OptionalField(key: "regulated_market_status")
    var regulatedMarketStatus: String?

    @OptionalField(key: "regulated_market_source")
    var regulatedMarketSource: String?

    @OptionalField(key: "regulated_market_reviewed_at")
    var regulatedMarketReviewedAt: Date?

    @Field(key: "currency")
    var currency: String

    @Field(key: "name")
    var name: String?

    @OptionalField(key: "instrument_type")
    var instrumentType: String?

    @OptionalField(key: "fund_classification")
    var fundClassification: String?

    @OptionalField(key: "isin")
    var isin: String?

    @OptionalField(key: "cusip")
    var cusip: String?

    @OptionalField(key: "tax_identity_group")
    var taxIdentityGroup: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        conid: String,
        symbol: String,
        exchange: String,
        currency: String,
        name: String? = nil
    ) {
        self.id = id
        self.conid = conid
        self.symbol = symbol
        self.exchange = exchange
        self.currency = currency
        self.name = name
    }
}
