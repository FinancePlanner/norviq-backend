import Fluent
import Foundation
import StockPlanShared
import Vapor

enum PilotTradeSide: String, Codable, Sendable {
    case buy
    case sell
    /// "Sale (Full)": the pilot no longer holds the position.
    case sellFull = "sell_full"
    /// A 13F holding row: a position at period end, not a trade.
    case hold
}

enum PilotInstrumentKind: String, Codable, Sendable {
    case stock
    case call
    case put
}

final class Pilot: Model, @unchecked Sendable {
    static let schema = "pilots"

    @ID(key: .id) var id: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "slug") var slug: String
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "chamber") var chamber: String?
    @OptionalField(key: "bioguide_id") var bioguideId: String?
    @OptionalField(key: "cik") var cik: String?
    @Field(key: "name_aliases") var nameAliases: [String]
    @Field(key: "active") var active: Bool
    @OptionalField(key: "last_ingested_at") var lastIngestedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, kind: PilotKind, slug: String, displayName: String, chamber: String? = nil, bioguideId: String? = nil, cik: String? = nil, nameAliases: [String] = [], active: Bool = true) {
        self.id = id
        self.kind = kind.rawValue
        self.slug = slug
        self.displayName = displayName
        self.chamber = chamber
        self.bioguideId = bioguideId
        self.cik = cik
        self.nameAliases = nameAliases
        self.active = active
    }

    var pilotKind: PilotKind {
        PilotKind(rawValue: kind) ?? .politician
    }
}

final class PilotDisclosureRecord: Model, @unchecked Sendable {
    static let schema = "pilot_disclosures"

    @ID(key: .id) var id: UUID?
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "source_key") var sourceKey: String
    @Field(key: "symbol") var symbol: String
    @Field(key: "side") var side: String
    @Field(key: "instrument") var instrument: String
    @OptionalField(key: "transaction_date") var transactionDate: String?
    @OptionalField(key: "disclosure_date") var disclosureDate: String?
    @OptionalField(key: "amount_min") var amountMin: Double?
    @OptionalField(key: "amount_max") var amountMax: Double?
    @OptionalField(key: "shares") var shares: Double?
    @OptionalField(key: "market_value") var marketValue: Double?
    @OptionalField(key: "period") var period: String?
    @Field(key: "discovered_at") var discoveredAt: Date

    init() {}

    init(id: UUID? = nil, pilotId: UUID, sourceKey: String, symbol: String, side: PilotTradeSide, instrument: PilotInstrumentKind, transactionDate: String? = nil, disclosureDate: String? = nil, amountMin: Double? = nil, amountMax: Double? = nil, shares: Double? = nil, marketValue: Double? = nil, period: String? = nil, discoveredAt: Date = Date()) {
        self.id = id
        self.pilotId = pilotId
        self.sourceKey = sourceKey
        self.symbol = symbol
        self.side = side.rawValue
        self.instrument = instrument.rawValue
        self.transactionDate = transactionDate
        self.disclosureDate = disclosureDate
        self.amountMin = amountMin
        self.amountMax = amountMax
        self.shares = shares
        self.marketValue = marketValue
        self.period = period
        self.discoveredAt = discoveredAt
    }
}

final class PilotBookVersion: Model, @unchecked Sendable {
    static let schema = "pilot_book_versions"

    @ID(key: .id) var id: UUID?
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "version") var version: Int
    @Field(key: "computed_at") var computedAt: Date
    @Field(key: "weights") var weights: [String: Double]
    @Field(key: "skipped_puts") var skippedPuts: Int

    init() {}

    init(id: UUID? = nil, pilotId: UUID, version: Int, computedAt: Date, weights: [String: Double], skippedPuts: Int) {
        self.id = id
        self.pilotId = pilotId
        self.version = version
        self.computedAt = computedAt
        self.weights = weights
        self.skippedPuts = skippedPuts
    }
}

final class PilotFollow: Model, @unchecked Sendable {
    static let schema = "pilot_follows"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "target_kind") var targetKind: String
    @OptionalField(key: "portfolio_list_id") var portfolioListId: UUID?
    @OptionalField(key: "watchlist_list_id") var watchlistListId: UUID?
    @OptionalField(key: "starting_capital") var startingCapital: Double?
    @Field(key: "currency") var currency: String
    @Field(key: "applied_version") var appliedVersion: Int
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, pilotId: UUID, targetKind: PilotFollowTargetKind, portfolioListId: UUID? = nil, watchlistListId: UUID? = nil, startingCapital: Double? = nil, currency: String = "USD") {
        self.id = id
        self.userId = userId
        self.pilotId = pilotId
        self.targetKind = targetKind.rawValue
        self.portfolioListId = portfolioListId
        self.watchlistListId = watchlistListId
        self.startingCapital = startingCapital
        self.currency = currency
        appliedVersion = 0
        status = PilotFollowStatus.active.rawValue
    }

    var target: PilotFollowTargetKind {
        PilotFollowTargetKind(rawValue: targetKind) ?? .portfolio
    }
}

final class PilotFollowEvent: Model, @unchecked Sendable {
    static let schema = "pilot_follow_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "follow_id") var followId: UUID
    @Field(key: "book_version") var bookVersion: Int
    @Field(key: "kind") var kind: String
    @Field(key: "symbol") var symbol: String
    @OptionalField(key: "quantity") var quantity: Double?
    @OptionalField(key: "price") var price: Double?
    @Field(key: "priced_at") var pricedAt: Date
    @OptionalField(key: "note") var note: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, followId: UUID, bookVersion: Int, kind: String, symbol: String, quantity: Double? = nil, price: Double? = nil, pricedAt: Date, note: String? = nil) {
        self.id = id
        self.followId = followId
        self.bookVersion = bookVersion
        self.kind = kind
        self.symbol = symbol
        self.quantity = quantity
        self.price = price
        self.pricedAt = pricedAt
        self.note = note
    }
}

final class PilotFollowSnapshot: Model, @unchecked Sendable {
    static let schema = "pilot_follow_snapshots"

    @ID(key: .id) var id: UUID?
    @Field(key: "follow_id") var followId: UUID
    @Field(key: "captured_on") var capturedOn: Date
    @Field(key: "value") var value: Double
    @Field(key: "cash") var cash: Double

    init() {}

    init(id: UUID? = nil, followId: UUID, capturedOn: Date, value: Double, cash: Double) {
        self.id = id
        self.followId = followId
        self.capturedOn = capturedOn
        self.value = value
        self.cash = cash
    }
}
