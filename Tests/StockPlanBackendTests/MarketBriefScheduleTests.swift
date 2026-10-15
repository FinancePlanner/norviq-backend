import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief schedule")
struct MarketBriefScheduleTests {
    private func at(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    private func due(_ date: String, _ slot: MarketBriefSlot) -> MarketBriefSchedule.Due {
        MarketBriefSchedule.Due(tradingDate: date, slot: slot)
    }

    @Test("Winter (WET, UTC+0): morning opens at 08:15 UTC")
    func winterMorning() throws {
        // Friday 2026-03-27, two days before the clocks go forward.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-03-27T08:14:00Z")) == nil)
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-03-27T08:15:00Z")) == due("2026-03-27", .morning))
    }

    @Test("Summer (WEST, UTC+1): morning opens at 07:15 UTC")
    func summerMorning() throws {
        // Monday 2026-03-30, the first weekday after the change.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-03-30T07:14:00Z")) == nil)
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-03-30T07:15:00Z")) == due("2026-03-30", .morning))
    }

    @Test("Evening either side of the October change")
    func eveningAcrossOctoberChange() throws {
        // Friday 2026-10-23 is still WEST: 22:30 Lisbon is 21:30 UTC.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-23T21:29:00Z")) == nil)
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-23T21:30:00Z")) == due("2026-10-23", .evening))
        // Monday 2026-10-26 is WET: 08:15 Lisbon is 08:15 UTC.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-26T08:15:00Z")) == due("2026-10-26", .morning))
    }

    @Test("A late boot still catches the morning; noon closes it")
    func lateBootAndWindowEnd() throws {
        // Wednesday 2026-10-07, WEST. 11:59 Lisbon = 10:59 UTC.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-07T10:59:00Z")) == due("2026-10-07", .morning))
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-07T11:00:00Z")) == nil)
    }

    @Test("Evening runs to local midnight and belongs to that Lisbon date")
    func eveningUntilMidnight() throws {
        // Thursday 2026-10-08 23:59 Lisbon = 22:59 UTC; Friday 00:00 Lisbon = 23:00 UTC.
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-08T22:59:00Z")) == due("2026-10-08", .evening))
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-08T23:00:00Z")) == nil)
    }

    @Test("Weekends never run")
    func weekend() throws {
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-10T09:00:00Z")) == nil) // Saturday
        #expect(try MarketBriefSchedule.dueSlot(now: at("2026-10-11T21:45:00Z")) == nil) // Sunday
    }

    @Test("localDate uses Lisbon, not UTC")
    func localDate() throws {
        // 23:30 UTC on 2026-10-08 is already 00:30 on the 9th in Lisbon (WEST).
        #expect(try MarketBriefSchedule.localDate(at("2026-10-08T23:30:00Z")) == "2026-10-09")
    }
}
