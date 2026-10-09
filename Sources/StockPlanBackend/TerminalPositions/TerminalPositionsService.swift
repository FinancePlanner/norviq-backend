import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Rules and persistence for terminal position sizing. Stateless; the
/// controllers, the action catalog and the tests all go through this.
///
/// Share count and market cap are user assumptions and may be saved as zero
/// or negative mid-edit: the row then reports `scenarioError` instead of
/// numbers. Everything else that would make the maths meaningless is a 422.
struct TerminalPositionsService: Sendable {
    static let clearablePositionFields: Set<String> = ["sharesOutstanding", "currentSharePrice", "notes"]
    static let clearableAutobuyFields: Set<String> = ["ticker", "percent"]
    static let maxNotesLength = 1000
    static let maxLabelLength = 80

    /// Fields `set_terminal_scenario` may write. All optional; a new row needs
    /// share count, market cap and value wanted.
    struct ScenarioFields: Sendable, Equatable {
        var terminalShareCount: Double?
        var terminalMarketCap: Double?
        var valueWanted: Double?
        var sharesOwned: Double?
        var sharesOutstanding: Double?
        var currentSharePrice: Double?

        init(
            terminalShareCount: Double? = nil,
            terminalMarketCap: Double? = nil,
            valueWanted: Double? = nil,
            sharesOwned: Double? = nil,
            sharesOutstanding: Double? = nil,
            currentSharePrice: Double? = nil
        ) {
            self.terminalShareCount = terminalShareCount
            self.terminalMarketCap = terminalMarketCap
            self.valueWanted = valueWanted
            self.sharesOwned = sharesOwned
            self.sharesOutstanding = sharesOutstanding
            self.currentSharePrice = currentSharePrice
        }
    }

    // MARK: - Validation

    static func normalisedTicker(_ raw: String) throws -> String {
        let ticker = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker.wholeMatch(of: #/[A-Z0-9.\-]{1,12}/#) != nil else {
            throw Abort(.unprocessableEntity, reason: "ticker must be 1-12 letters, digits, '.' or '-'")
        }
        return ticker
    }

    /// Largest accepted value for any numeric input, so sums of a user's rows stay finite.
    static let maxInput = 1e18

    static func finite(_ value: Double, _ field: String) throws -> Double {
        guard value.isFinite else { throw Abort(.unprocessableEntity, reason: "\(field) must be a number") }
        guard abs(value) <= maxInput else { throw Abort(.unprocessableEntity, reason: "\(field) is too large") }
        return value
    }

    static func nonNegative(_ value: Double, _ field: String) throws -> Double {
        guard try finite(value, field) >= 0 else {
            throw Abort(.unprocessableEntity, reason: "\(field) must be zero or more")
        }
        return value
    }

    static func positive(_ value: Double, _ field: String) throws -> Double {
        guard try finite(value, field) > 0 else {
            throw Abort(.unprocessableEntity, reason: "\(field) must be greater than zero")
        }
        return value
    }

    static func notes(_ raw: String?) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxNotesLength else {
            throw Abort(.unprocessableEntity, reason: "notes must be \(maxNotesLength) characters or fewer")
        }
        return trimmed
    }

    static func label(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLabelLength else {
            throw Abort(.unprocessableEntity, reason: "label must be 1-\(maxLabelLength) characters")
        }
        return trimmed
    }

    static func clearFields(_ raw: [String]?, allowed: Set<String>) throws -> Set<String> {
        let requested = Set(raw ?? [])
        let unknown = requested.subtracting(allowed)
        guard unknown.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "cannot clear: \(unknown.sorted().joined(separator: ", "))")
        }
        return requested
    }

    static func validatedPercent(_ percent: Double?, cadence: AutobuyCadence) throws -> Double? {
        guard cadence != .unknown else { throw Abort(.unprocessableEntity, reason: "unknown cadence") }
        if let percent {
            guard percent.isFinite, percent > 0, percent <= 1 else {
                throw Abort(.unprocessableEntity, reason: "percent must be between 0 and 1 (0.04 = 4%)")
            }
        }
        if cadence == .percentOfContribution, percent == nil {
            throw Abort(.unprocessableEntity, reason: "percentOfContribution needs a percent")
        }
        return percent
    }

    // MARK: - Positions

    func list(userId: UUID, ticker: String? = nil, on db: any Database) async throws -> [TerminalPositionRecord] {
        var query = TerminalPositionRecord.owned(by: userId, on: db)
        if let ticker = ticker?.trimmingCharacters(in: .whitespacesAndNewlines), !ticker.isEmpty {
            query = query.filter(\.$ticker == ticker.uppercased())
        }
        return try await query.sort(\.$sortOrder).sort(\.$createdAt).all()
    }

    func find(userId: UUID, id: UUID, on db: any Database) async throws -> TerminalPositionRecord {
        guard let row = try await TerminalPositionRecord.owned(by: userId, on: db).filter(\.$id == id).first() else {
            throw Abort(.notFound, reason: "Terminal position not found.")
        }
        return row
    }

    func create(userId: UUID, _ input: TerminalPositionCreateRequest, on db: any Database) async throws -> TerminalPositionRecord {
        let last = try await TerminalPositionRecord.owned(by: userId, on: db).sort(\.$sortOrder, .descending).first()
        let record = try TerminalPositionRecord(
            userId: userId,
            ticker: Self.normalisedTicker(input.ticker),
            sharesOutstanding: input.sharesOutstanding.map { try Self.positive($0, "sharesOutstanding") },
            terminalShareCount: Self.finite(input.terminalShareCount, "terminalShareCount"),
            terminalMarketCap: Self.finite(input.terminalMarketCap, "terminalMarketCap"),
            valueWanted: Self.nonNegative(input.valueWanted, "valueWanted"),
            sharesOwned: Self.nonNegative(input.sharesOwned ?? 0, "sharesOwned"),
            currentSharePrice: input.currentSharePrice.map { try Self.positive($0, "currentSharePrice") },
            notes: Self.notes(input.notes),
            sortOrder: (last?.sortOrder ?? -1) + 1
        )
        try await record.save(on: db)
        return record
    }

    func update(
        userId: UUID,
        id: UUID,
        _ input: TerminalPositionUpdateRequest,
        on db: any Database
    ) async throws -> TerminalPositionRecord {
        let record = try await find(userId: userId, id: id, on: db)
        let clear = try Self.clearFields(input.clear, allowed: Self.clearablePositionFields)
        if let ticker = input.ticker {
            record.ticker = try Self.normalisedTicker(ticker)
        }
        if let value = input.sharesOutstanding {
            record.sharesOutstanding = try Self.positive(value, "sharesOutstanding")
        }
        if let value = input.terminalShareCount {
            record.terminalShareCount = try Self.finite(value, "terminalShareCount")
        }
        if let value = input.terminalMarketCap {
            record.terminalMarketCap = try Self.finite(value, "terminalMarketCap")
        }
        if let value = input.valueWanted {
            record.valueWanted = try Self.nonNegative(value, "valueWanted")
        }
        if let value = input.sharesOwned {
            record.sharesOwned = try Self.nonNegative(value, "sharesOwned")
        }
        if let value = input.currentSharePrice {
            record.currentSharePrice = try Self.positive(value, "currentSharePrice")
        }
        if input.notes != nil {
            record.notes = try Self.notes(input.notes)
        }
        if clear.contains("sharesOutstanding") {
            record.sharesOutstanding = nil
        }
        if clear.contains("currentSharePrice") {
            record.currentSharePrice = nil
        }
        if clear.contains("notes") {
            record.notes = nil
        }
        try await record.save(on: db)
        return record
    }

    func delete(userId: UUID, id: UUID, on db: any Database) async throws {
        try await find(userId: userId, id: id, on: db).delete(on: db)
    }

    /// The copy goes right after its source; later rows shift down by one.
    func duplicate(userId: UUID, id: UUID, on db: any Database) async throws -> TerminalPositionRecord {
        let source = try await find(userId: userId, id: id, on: db)
        let copy = TerminalPositionRecord(
            userId: userId,
            ticker: source.ticker,
            sharesOutstanding: source.sharesOutstanding,
            terminalShareCount: source.terminalShareCount,
            terminalMarketCap: source.terminalMarketCap,
            valueWanted: source.valueWanted,
            sharesOwned: source.sharesOwned,
            currentSharePrice: source.currentSharePrice,
            notes: source.notes,
            sortOrder: source.sortOrder + 1
        )
        try await db.transaction { tx in
            let later = try await TerminalPositionRecord.owned(by: userId, on: tx)
                .filter(\.$sortOrder > source.sortOrder)
                .all()
            for row in later {
                row.sortOrder += 1
                try await row.save(on: tx)
            }
            try await copy.save(on: tx)
        }
        return copy
    }

    func reorder(userId: UUID, ids: [String], on db: any Database) async throws -> [TerminalPositionRecord] {
        let uuids = try ids.map { raw in
            guard let id = UUID(uuidString: raw) else { throw Abort(.unprocessableEntity, reason: "invalid id \(raw)") }
            return id
        }
        let rows = try await TerminalPositionRecord.owned(by: userId, on: db).all()
        let owned = Set(rows.compactMap(\.id))
        guard uuids.count == rows.count, Set(uuids).count == uuids.count, Set(uuids) == owned else {
            throw Abort(.unprocessableEntity, reason: "ids must list every terminal position exactly once")
        }
        try await db.transaction { tx in
            for (index, id) in uuids.enumerated() {
                guard let row = rows.first(where: { $0.id == id }) else { continue }
                row.sortOrder = index
                try await row.save(on: tx)
            }
        }
        return try await list(userId: userId, on: db)
    }

    /// Assistant/MCP write: update the first row for the ticker, or create one.
    func upsertScenario(
        userId: UUID,
        ticker raw: String,
        fields: ScenarioFields,
        on db: any Database
    ) async throws -> TerminalPositionRecord {
        let ticker = try Self.normalisedTicker(raw)
        if let existing = try await list(userId: userId, ticker: ticker, on: db).first {
            return try await update(
                userId: userId,
                id: existing.requireID(),
                TerminalPositionUpdateRequest(
                    sharesOutstanding: fields.sharesOutstanding,
                    terminalShareCount: fields.terminalShareCount,
                    terminalMarketCap: fields.terminalMarketCap,
                    valueWanted: fields.valueWanted,
                    sharesOwned: fields.sharesOwned,
                    currentSharePrice: fields.currentSharePrice
                ),
                on: db
            )
        }
        guard let count = fields.terminalShareCount, let cap = fields.terminalMarketCap, let value = fields.valueWanted else {
            throw Abort(
                .unprocessableEntity,
                reason: "a new scenario needs terminalShareCount, terminalMarketCap and valueWanted"
            )
        }
        return try await create(
            userId: userId,
            TerminalPositionCreateRequest(
                ticker: ticker,
                sharesOutstanding: fields.sharesOutstanding,
                terminalShareCount: count,
                terminalMarketCap: cap,
                valueWanted: value,
                sharesOwned: fields.sharesOwned,
                currentSharePrice: fields.currentSharePrice
            ),
            on: db
        )
    }

    // MARK: - Autobuys

    func listAutobuys(userId: UUID, on db: any Database) async throws -> [AutobuyRecord] {
        try await AutobuyRecord.owned(by: userId, on: db).sort(\.$createdAt).all()
    }

    func findAutobuy(userId: UUID, id: UUID, on db: any Database) async throws -> AutobuyRecord {
        guard let row = try await AutobuyRecord.owned(by: userId, on: db).filter(\.$id == id).first() else {
            throw Abort(.notFound, reason: "Autobuy not found.")
        }
        return row
    }

    func createAutobuy(userId: UUID, _ input: AutobuyCreateRequest, on db: any Database) async throws -> AutobuyRecord {
        let record = try AutobuyRecord(
            userId: userId,
            ticker: input.ticker.map { try Self.normalisedTicker($0) },
            label: Self.label(input.label),
            amount: Self.nonNegative(input.amount, "amount"),
            cadence: input.cadence,
            percent: Self.validatedPercent(input.percent, cadence: input.cadence),
            active: input.active ?? true
        )
        try await record.save(on: db)
        return record
    }

    func updateAutobuy(userId: UUID, id: UUID, _ input: AutobuyUpdateRequest, on db: any Database) async throws -> AutobuyRecord {
        let record = try await findAutobuy(userId: userId, id: id, on: db)
        let clear = try Self.clearFields(input.clear, allowed: Self.clearableAutobuyFields)
        if let ticker = input.ticker {
            record.ticker = try Self.normalisedTicker(ticker)
        }
        if let label = input.label {
            record.label = try Self.label(label)
        }
        if let amount = input.amount {
            record.amount = try Self.nonNegative(amount, "amount")
        }
        if let cadence = input.cadence {
            record.cadence = cadence.rawValue
        }
        if let percent = input.percent {
            record.percent = percent
        }
        if let active = input.active {
            record.active = active
        }
        if clear.contains("ticker") {
            record.ticker = nil
        }
        if clear.contains("percent") {
            record.percent = nil
        }
        record.percent = try Self.validatedPercent(record.percent, cadence: record.cadenceValue)
        try await record.save(on: db)
        return record
    }

    func deleteAutobuy(userId: UUID, id: UUID, on db: any Database) async throws {
        try await findAutobuy(userId: userId, id: id, on: db).delete(on: db)
    }

    static func monthlyTotal(_ rows: [AutobuyRecord]) -> Double {
        finiteSum(rows.map { row in
            row.active ? AutobuyMath.monthlyEquivalent(amount: row.amount, cadence: row.cadenceValue, percent: row.percent) ?? 0 : 0
        })
    }

    /// Sum that ignores non-finite terms and never overflows to infinity,
    /// so the JSON encoder cannot fail on a stored extreme value.
    static func finiteSum(_ values: [Double]) -> Double {
        values.reduce(0) { total, value in
            let next = total + value
            return value.isFinite && next.isFinite ? next : total
        }
    }

    // MARK: - Currency and summary

    /// There is no user-level currency: use the default portfolio's, then any
    /// portfolio's, then the deployment default.
    func currency(userId: UUID, on db: any Database) async throws -> String {
        if let preferred = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$isDefault == true)
            .first()
        {
            return preferred.baseCurrency
        }
        if let any = try await PortfolioList.query(on: db).filter(\.$userId == userId).first() {
            return any.baseCurrency
        }
        return Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
    }

    func summary(userId: UUID, on db: any Database) async throws -> TerminalPositionsSummaryResponse {
        let positions = try await list(userId: userId, on: db).map { $0.toResponse() }
        let valid = positions.filter { $0.scenarioError == nil }
        let priced = valid.compactMap(\.capitalAtTodayPrice)
        let autobuys = try await listAutobuys(userId: userId, on: db)
        return try await TerminalPositionsSummaryResponse(
            currency: currency(userId: userId, on: db),
            positionCount: positions.count,
            totalValueWanted: Self.finiteSum(valid.map(\.valueWanted)),
            totalGapValueAtTerminal: Self.finiteSum(valid.map { $0.gapValueAtTerminal ?? 0 }),
            totalCapitalAtTodayPrice: priced.isEmpty ? nil : Self.finiteSum(priced),
            pricedPositionCount: priced.count,
            monthlyAutobuyTotal: Self.monthlyTotal(autobuys),
            topPositions: Array(valid.sorted { $0.valueWanted > $1.valueWanted }.prefix(3))
        )
    }
}
