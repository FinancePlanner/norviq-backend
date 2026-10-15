import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief repository", .serialized)
struct MarketBriefRepositoryTests {
    private let repo = DatabaseMarketBriefRepository()

    private func both(_ date: String, _ slot: MarketBriefSlot) -> [MarketBriefResponse] {
        [MarketBriefFixtures.response(date: date, slot: slot, language: "en"),
         MarketBriefFixtures.response(date: date, slot: slot, language: "pt-PT")]
    }

    @Test("Saving both languages makes the slot exist and each language readable")
    func saveAndFind() async throws {
        try await MarketBriefFixtures.withApp { app in
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db) == false)
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db))
            let pt = try await repo.find(tradingDate: "2026-10-08", slot: .morning, language: "pt-PT", on: app.db)
            #expect(pt?.greeting == "Bom dia,")
        }
    }

    @Test("Latest is the most recently generated brief for the language")
    func latest() async throws {
        try await MarketBriefFixtures.withApp { app in
            let morning = Date(timeIntervalSince1970: 1_791_500_000)
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: morning, on: app.db)
            try await repo.save(both("2026-10-08", .evening), model: "m", generatedAt: morning.addingTimeInterval(14 * 3600), on: app.db)
            #expect(try await repo.latest(language: "en", on: app.db)?.slot == .evening)
            #expect(try await repo.latest(language: "pt-PT", on: app.db)?.language == "pt-PT")
            #expect(try await repo.latest(language: "de", on: app.db) == nil)
        }
    }

    @Test("A second save for the same slot violates the unique key")
    func duplicateRejected() async throws {
        try await MarketBriefFixtures.withApp { app in
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            do {
                try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
                Issue.record("expected a unique-key violation")
            } catch {
                #expect((error as? any DatabaseError)?.isConstraintFailure == true)
            }
        }
    }

    @Test("Delete removes both languages of a slot")
    func deleteSlot() async throws {
        try await MarketBriefFixtures.withApp { app in
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            try await repo.delete(tradingDate: "2026-10-08", slot: .morning, on: app.db)
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db) == false)
        }
    }

    @Test("A brief without a date or slot is refused before touching the database")
    func incompleteRefused() async throws {
        try await MarketBriefFixtures.withApp { app in
            await #expect(throws: MarketBriefError.incompleteBrief) {
                try await repo.save([.empty(language: "en", enabled: true)], model: "m", generatedAt: Date(), on: app.db)
            }
        }
    }

    @Test("Latest follows the trading date, not when a brief was (re)generated")
    func latestByTradingDate() async throws {
        try await MarketBriefFixtures.withApp { app in
            let base = Date(timeIntervalSince1970: 1_791_500_000)
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: base, on: app.db)
            // A replaced brief for an earlier day, written later.
            try await repo.save(both("2026-10-07", .evening), model: "m", generatedAt: base.addingTimeInterval(3600), on: app.db)
            let latest = try await repo.latest(language: "en", on: app.db)
            #expect(latest?.tradingDate == "2026-10-08")
            #expect(latest?.slot == .morning)
        }
    }

    @Test("Previous: an evening points at the same day's morning, a morning at the last earlier brief")
    func previous() async throws {
        try await MarketBriefFixtures.withApp { app in
            let at = Date(timeIntervalSince1970: 1_791_500_000)
            // Friday evening, then nothing over the weekend, then Monday.
            try await repo.save(both("2026-10-09", .evening), model: "m", generatedAt: at, on: app.db)
            try await repo.save(both("2026-10-12", .morning), model: "m", generatedAt: at, on: app.db)
            try await repo.save(both("2026-10-12", .evening), model: "m", generatedAt: at, on: app.db)

            let mondayEvening = try await repo.previous(tradingDate: "2026-10-12", slot: .evening, language: "en", on: app.db)
            #expect(mondayEvening == MarketBriefRef(slot: .morning, tradingDate: "2026-10-12"))
            let mondayMorning = try await repo.previous(tradingDate: "2026-10-12", slot: .morning, language: "pt-PT", on: app.db)
            #expect(mondayMorning == MarketBriefRef(slot: .evening, tradingDate: "2026-10-09"))
            #expect(try await repo.previous(tradingDate: "2026-10-09", slot: .evening, language: "en", on: app.db) == nil)
        }
    }

    @Test("Previous: an evening with no morning that day falls back to an earlier day")
    func previousSkipsMissingMorning() async throws {
        try await MarketBriefFixtures.withApp { app in
            let at = Date(timeIntervalSince1970: 1_791_500_000)
            try await repo.save(both("2026-10-07", .morning), model: "m", generatedAt: at, on: app.db)
            try await repo.save(both("2026-10-08", .evening), model: "m", generatedAt: at, on: app.db)
            let ref = try await repo.previous(tradingDate: "2026-10-08", slot: .evening, language: "en", on: app.db)
            #expect(ref == MarketBriefRef(slot: .morning, tradingDate: "2026-10-07"))
        }
    }
}
