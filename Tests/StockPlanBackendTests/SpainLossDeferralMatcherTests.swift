import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Spain loss deferral matcher")
struct SpainLossDeferralMatcherTests {
    private let matcher = SpainLossDeferralMatcher()
    private let calendar = Calendar(identifier: .gregorian)
    private let saleDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `matches retained homogeneous lots in FIFO order`() throws {
        let older = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
        let newer = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000022"))
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 10,
            realizedPnL: -500,
            replacements: [
                .init(lotId: newer, acquisitionDate: saleDate.addingTimeInterval(10 * 86400), remainingQuantity: 8),
                .init(lotId: older, acquisitionDate: saleDate.addingTimeInterval(-10 * 86400), remainingQuantity: 4),
            ],
            calendar: calendar
        )
        #expect(allocations.map(\.replacementLotId) == [older, newer])
        #expect(allocations.map(\.matchedQuantity) == [4, 6])
        #expect(allocations.map(\.deferredLoss) == [200, 300])
    }

    @Test
    func `uses calendar-month boundaries and excludes later acquisitions`() throws {
        let inside = UUID()
        let outside = UUID()
        let end = try #require(calendar.date(byAdding: .month, value: 2, to: saleDate))
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 5,
            realizedPnL: -100,
            replacements: [
                .init(lotId: inside, acquisitionDate: end, remainingQuantity: 2),
                .init(lotId: outside, acquisitionDate: end.addingTimeInterval(1), remainingQuantity: 3),
            ],
            calendar: calendar
        )
        #expect(allocations == [.init(replacementLotId: inside, matchedQuantity: 2, deferredLoss: 40)])
    }

    @Test
    func `caps deferral at replacement quantity still held`() {
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 10,
            realizedPnL: -200,
            replacements: [
                .init(lotId: UUID(), acquisitionDate: saleDate, remainingQuantity: 3),
            ],
            calendar: calendar
        )
        #expect(allocations.map(\.matchedQuantity) == [3])
        #expect(allocations.map(\.deferredLoss) == [60])
    }

    @Test
    func `supports the twelve-month unlisted-security window`() throws {
        let inside = UUID()
        let outside = UUID()
        let end = try #require(calendar.date(byAdding: .month, value: 12, to: saleDate))
        let allocations = matcher.match(
            saleDate: saleDate,
            soldQuantity: 4,
            realizedPnL: -80,
            replacements: [
                .init(lotId: inside, acquisitionDate: end, remainingQuantity: 2),
                .init(lotId: outside, acquisitionDate: end.addingTimeInterval(1), remainingQuantity: 2),
            ],
            windowMonths: 12,
            calendar: calendar
        )
        #expect(allocations == [.init(replacementLotId: inside, matchedQuantity: 2, deferredLoss: 40)])
    }

    @Test
    func `does not defer gains`() {
        #expect(matcher.match(
            saleDate: saleDate,
            soldQuantity: 5,
            realizedPnL: 100,
            replacements: [.init(lotId: UUID(), acquisitionDate: saleDate, remainingQuantity: 5)],
            calendar: calendar
        ).isEmpty)
    }
}
