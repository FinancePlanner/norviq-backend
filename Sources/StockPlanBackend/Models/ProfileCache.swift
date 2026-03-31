import Fluent
import Vapor
import Foundation

final class ProfileCache: Model, Content, @unchecked Sendable {
    static let schema = "profile_cache"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

    @Field(key: "symbol")
    var symbol: String

    @OptionalField(key: "country")
    var country: String?

    @OptionalField(key: "currency")
    var currency: String?

    @OptionalField(key: "estimate_currency")
    var estimateCurrency: String?

    @OptionalField(key: "exchange")
    var exchange: String?

    @OptionalField(key: "finnhub_industry")
    var finnhubIndustry: String?

    @OptionalField(key: "ipo")
    var ipo: String?

    @OptionalField(key: "logo")
    var logo: String?

    @OptionalField(key: "market_capitalization")
    var marketCapitalization: Double?

    @OptionalField(key: "name")
    var name: String?

    @OptionalField(key: "phone")
    var phone: String?

    @OptionalField(key: "share_outstanding")
    var shareOutstanding: Double?

    @OptionalField(key: "ticker")
    var ticker: String?

    @OptionalField(key: "weburl")
    var weburl: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        country: String? = nil,
        currency: String? = nil,
        estimateCurrency: String? = nil,
        exchange: String? = nil,
        finnhubIndustry: String? = nil,
        ipo: String? = nil,
        logo: String? = nil,
        marketCapitalization: Double? = nil,
        name: String? = nil,
        phone: String? = nil,
        shareOutstanding: Double? = nil,
        ticker: String? = nil,
        weburl: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.country = country
        self.currency = currency
        self.estimateCurrency = estimateCurrency
        self.exchange = exchange
        self.finnhubIndustry = finnhubIndustry
        self.ipo = ipo
        self.logo = logo
        self.marketCapitalization = marketCapitalization
        self.name = name
        self.phone = phone
        self.shareOutstanding = shareOutstanding
        self.ticker = ticker
        self.weburl = weburl
    }
}
