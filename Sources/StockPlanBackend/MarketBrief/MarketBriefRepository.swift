import Fluent
import Foundation
import StockPlanShared

protocol MarketBriefRepository: Sendable {
    func exists(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws -> Bool
    /// All languages of one slot in one transaction: a reader never sees en
    /// without pt-PT.
    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws
    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws
    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse?
    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse?
}

struct DatabaseMarketBriefRepository: MarketBriefRepository {
    func exists(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws -> Bool {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .count() > 0
    }

    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try briefs.map { brief in
            guard let tradingDate = brief.tradingDate, let slot = brief.slot else {
                throw MarketBriefError.incompleteBrief
            }
            return try MarketBriefRecord(
                tradingDate: tradingDate,
                slot: slot.rawValue,
                language: brief.language,
                payload: String(decoding: encoder.encode(brief), as: UTF8.self),
                model: model,
                degraded: brief.degraded,
                generatedAt: generatedAt
            )
        }
        try await db.transaction { tx in
            for record in records {
                try await record.save(on: tx)
            }
        }
    }

    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .delete()
    }

    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$language == language)
            // By trading day, not by write time: a `--replace` run must not
            // make an old brief the current card. Same day: "evening" sorts
            // before "morning", and evening is the later brief.
            .sort(\.$tradingDate, .descending)
            .sort(\.$slot, .ascending)
            .sort(\.$generatedAt, .descending)
            .first()
            .map(decode)
    }

    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .filter(\.$language == language)
            .first()
            .map(decode)
    }

    private func decode(_ record: MarketBriefRecord) throws -> MarketBriefResponse {
        try JSONDecoder().decode(MarketBriefResponse.self, from: Data(record.payload.utf8))
    }
}
