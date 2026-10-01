import Crypto
import Foundation

/// Congressional disclosures from FMP's free "latest" feeds.
///
/// The free plan returns only the newest 25 rows per chamber (page 0), so
/// there is no history to search. Each ingestion run reads the feed once per
/// chamber and hands each pilot its own rows. The memo keeps 15 pilots from
/// costing 15 requests against a 250-request daily budget.
struct FMPCongressPilotSource: PilotDisclosureSource {
    typealias Fetch = @Sendable (_ chamber: String) async throws -> [FMPCongressTrade]

    static let feedLimit = 25

    private let fetch: Fetch
    private let memo: FeedMemo

    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init, fetch: @escaping Fetch) {
        self.fetch = fetch
        memo = FeedMemo(ttl: ttl, now: now)
    }

    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        guard let chamber = pilot.chamber else { return [] }
        let rows = try await memo.rows(chamber: chamber, fetch: fetch)
        let aliases = Set(pilot.aliases.map(Self.normalizedName))
        var seen = Set<String>()
        var out: [PilotDisclosureInput] = []
        for wire in rows where Self.matches(wire, bioguideId: pilot.bioguideId, aliases: aliases) {
            guard let input = Self.input(from: wire, chamber: chamber), seen.insert(input.sourceKey).inserted else { continue }
            out.append(input)
        }
        return out
    }

    /// Bioguide ID when the row has one; otherwise an exact "First Last" alias.
    static func matches(_ wire: FMPCongressTrade, bioguideId: String?, aliases: Set<String>) -> Bool {
        if let id = wire.senateID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return id.caseInsensitiveCompare(bioguideId ?? "") == .orderedSame
        }
        return aliases.contains(normalizedName("\(wire.firstName ?? "") \(wire.lastName ?? "")"))
    }

    static func input(from wire: FMPCongressTrade, chamber: String) -> PilotDisclosureInput? {
        guard let symbol = wire.symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !symbol.isEmpty,
              let side = side(from: wire.type),
              let instrument = instrument(assetType: wire.assetType, description: wire.assetDescription)
        else { return nil }
        let bounds = CongressTrades.amountBounds(from: wire.amount)
        let keyMaterial = [chamber, wire.senateID ?? "", wire.firstName ?? "", wire.lastName ?? "", wire.owner ?? "", symbol,
                           wire.transactionDate ?? "", wire.type ?? "", wire.amount ?? "", wire.link ?? ""]
            .joined(separator: "|")
        let key = SHA256.hash(data: Data(keyMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        return PilotDisclosureInput(
            sourceKey: key,
            symbol: symbol,
            side: side,
            instrument: instrument,
            transactionDate: wire.transactionDate,
            disclosureDate: wire.disclosureDate,
            amountMin: bounds.min,
            amountMax: bounds.max,
            shares: nil,
            marketValue: nil,
            period: nil
        )
    }

    /// Purchase → buy; "Sale (Full)" → sellFull; any other sale → sell.
    /// Exchanges and unknown types carry no direction and are dropped.
    static func side(from raw: String?) -> PilotTradeSide? {
        guard let lowered = raw?.lowercased() else { return nil }
        if lowered.contains("purchase") {
            return .buy
        }
        if lowered.contains("sale") {
            return lowered.contains("full") ? .sellFull : .sell
        }
        return nil
    }

    /// Stocks and ETFs pass through; options become call or put. Bonds,
    /// mutual funds and anything else are dropped. A missing asset type is
    /// treated as stock, because the feed omits it for plain equity rows.
    static func instrument(assetType: String?, description: String?) -> PilotInstrumentKind? {
        let type = assetType?.lowercased() ?? ""
        if type.contains("option") {
            return (description?.lowercased().contains("put") ?? false) ? .put : .call
        }
        if type.isEmpty || type == "stock" || type.contains("etf") || type.contains("equity") || type.contains("common") {
            return .stock
        }
        return nil
    }

    static func normalizedName(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Per-chamber cache of the feed for one ingestion run.
private actor FeedMemo {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: (at: Date, rows: [FMPCongressTrade])] = [:]

    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.now = now
    }

    func rows(chamber: String, fetch: FMPCongressPilotSource.Fetch) async throws -> [FMPCongressTrade] {
        if let hit = cache[chamber], now().timeIntervalSince(hit.at) < ttl {
            return hit.rows
        }
        let rows = try await fetch(chamber)
        cache[chamber] = (now(), rows)
        return rows
    }
}
