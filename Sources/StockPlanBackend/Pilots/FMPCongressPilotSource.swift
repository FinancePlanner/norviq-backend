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
        // Ordinals are assigned over the whole chamber feed, in feed order,
        // before filtering, so they do not depend on which pilot asks.
        var occurrences: [String: Int] = [:]
        var out: [PilotDisclosureInput] = []
        for wire in rows {
            let material = Self.keyMaterial(wire, chamber: chamber)
            let ordinal = occurrences[material, default: 0]
            occurrences[material] = ordinal + 1
            guard Self.matches(wire, bioguideId: pilot.bioguideId, aliases: aliases),
                  let input = Self.input(from: wire, chamber: chamber, ordinal: ordinal) else { continue }
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

    static func keyMaterial(_ wire: FMPCongressTrade, chamber: String) -> String {
        let symbol = (wire.symbol ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var parts: [String] = [chamber, wire.senateID ?? "", wire.firstName ?? "", wire.lastName ?? "", wire.owner ?? ""]
        parts += [symbol, wire.transactionDate ?? "", wire.type ?? "", wire.amount ?? "", wire.link ?? ""]
        parts += [wire.assetType ?? "", wire.assetDescription ?? "", wire.disclosureDate ?? ""]
        return parts.joined(separator: "|")
    }

    static func input(from wire: FMPCongressTrade, chamber: String, ordinal: Int = 0) -> PilotDisclosureInput? {
        guard let symbol = wire.symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !symbol.isEmpty,
              let side = side(from: wire.type),
              let instrument = instrument(assetType: wire.assetType, description: wire.assetDescription)
        else { return nil }
        let bounds = CongressTrades.amountBounds(from: wire.amount)
        // The first occurrence keeps the bare material; repeats get "|#n".
        var keyMaterial = Self.keyMaterial(wire, chamber: chamber)
        if ordinal > 0 {
            keyMaterial += "|#\(ordinal)"
        }
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

    /// Stocks and ETFs pass through; options become call or put only when the
    /// description says so as a whole word ("Call options", "... Put"). An
    /// option whose description names neither is dropped, never guessed.
    /// Bonds, mutual funds and anything else are dropped. A missing asset type
    /// is treated as stock, because the feed omits it for plain equity rows.
    static func instrument(assetType: String?, description: String?) -> PilotInstrumentKind? {
        let type = assetType?.lowercased() ?? ""
        if type.contains("option") {
            let text = description ?? ""
            if text.range(of: #"\bputs?\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .put
            }
            if text.range(of: #"\bcalls?\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .call
            }
            return nil
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

/// Per-chamber cache of the feed for one ingestion run. Concurrent callers
/// share one in-flight fetch; a failed fetch is evicted so the next call retries.
private actor FeedMemo {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: (at: Date, task: Task<[FMPCongressTrade], Error>)] = [:]

    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.now = now
    }

    func rows(chamber: String, fetch: @escaping FMPCongressPilotSource.Fetch) async throws -> [FMPCongressTrade] {
        let entry: (at: Date, task: Task<[FMPCongressTrade], Error>)
        if let hit = cache[chamber], now().timeIntervalSince(hit.at) < ttl {
            entry = hit
        } else {
            entry = (now(), Task { try await fetch(chamber) })
            cache[chamber] = entry
        }
        do {
            return try await entry.task.value
        } catch {
            if let cur = cache[chamber], cur.at == entry.at {
                cache[chamber] = nil
            }
            throw error
        }
    }
}
