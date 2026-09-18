import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Institutional ownership")
struct InstitutionalOwnershipTests {
    // MARK: - Fixtures

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components) ?? Date()
    }

    private func holder(
        name: String?,
        shares: Double?,
        marketValue: Double? = 1000,
        changeInShares: Double? = 10,
        changePct: Double? = 1.5,
        weight: Double? = 0.25
    ) -> FMPInstitutionalHolder {
        FMPInstitutionalHolder(
            investorName: name,
            sharesNumber: shares,
            marketValue: marketValue,
            changeInSharesNumber: changeInShares,
            changeInSharesNumberPercentage: changePct,
            weight: weight
        )
    }

    // MARK: - Quarter derivation

    @Test(
        "The latest reported quarter is the calendar quarter before today's",
        arguments: [
            (2026, 9, 17, "2026Q2"),
            (2026, 1, 5, "2025Q4"),
            (2026, 3, 31, "2025Q4"),
            (2026, 4, 1, "2026Q1"),
            (2026, 6, 30, "2026Q1"),
            (2026, 7, 1, "2026Q2"),
            (2026, 12, 31, "2026Q3"),
        ]
    )
    func latestReportedQuarterIsThePreviousOne(year: Int, month: Int, dayOfMonth: Int, expected: String) {
        let quarter = MarketQuarter.latestReported(asOf: day(year, month, dayOfMonth))

        #expect(quarter.label == expected)
    }

    @Test("Stepping back from Q1 lands in the previous year's Q4")
    func steppingBackFromQ1WrapsTheYear() {
        let quarter = MarketQuarter(year: 2026, quarter: 1)

        #expect(quarter.previous() == MarketQuarter(year: 2025, quarter: 4))
        #expect(quarter.previous().label == "2025Q4")
    }

    @Test("Stepping back inside a year only moves the quarter")
    func steppingBackInsideAYearKeepsTheYear() {
        #expect(MarketQuarter(year: 2026, quarter: 3).previous() == MarketQuarter(year: 2026, quarter: 2))
    }

    // MARK: - Top holders

    @Test("Holders come back biggest first and capped at ten")
    func holdersAreSortedAndCappedAtTen() {
        let wire = (1 ... 14).map { holder(name: "Fund \($0)", shares: Double($0) * 100) }

        let holders = InstitutionalOwnership.holders(from: wire)

        #expect(holders.count == 10)
        #expect(holders.first?.name == "Fund 14")
        #expect(holders.first?.shares == 1400)
        #expect(holders.last?.name == "Fund 5")
        #expect(holders.map(\.shares) == (5 ... 14).reversed().map { Double($0) * 100 })
    }

    @Test("Fewer than ten holders come back whole")
    func fewerThanTenHoldersComeBackWhole() {
        let holders = InstitutionalOwnership.holders(from: [
            holder(name: "Fund A", shares: 10),
            holder(name: "Fund B", shares: 30),
        ])

        #expect(holders.map(\.name) == ["Fund B", "Fund A"])
    }

    @Test("A holder with no name or no share count is dropped, not defaulted to zero")
    func unusableHoldersAreDropped() {
        let holders = InstitutionalOwnership.holders(from: [
            holder(name: nil, shares: 500),
            holder(name: "Fund B", shares: nil),
            holder(name: "  ", shares: 400),
            holder(name: "Fund D", shares: 300),
        ])

        #expect(holders.map(\.name) == ["Fund D"])
    }

    @Test("Optional holder fields survive being absent upstream")
    func optionalHolderFieldsTolerateAbsence() throws {
        let holders = InstitutionalOwnership.holders(from: [
            holder(name: "Fund A", shares: 100, marketValue: nil, changeInShares: nil, changePct: nil, weight: nil),
        ])

        let only = try #require(holders.first)
        #expect(only.name == "Fund A")
        #expect(only.shares == 100)
        #expect(only.marketValue == nil)
        #expect(only.changeInShares == nil)
        #expect(only.changePct == nil)
        #expect(only.weightPct == nil)
    }

    // MARK: - Assembly

    @Test("Totals come from the positions summary when it is there")
    func totalsComeFromThePositionsSummary() {
        let response = InstitutionalOwnership.build(
            symbol: "AAPL",
            quarter: MarketQuarter(year: 2026, quarter: 2),
            wireHolders: [holder(name: "Fund A", shares: 100)],
            summary: FMPInstitutionalPositionsSummary(
                symbol: "AAPL",
                date: "2026-06-30",
                investorsHolding: 4821,
                numberOf13Fshares: 9_500_000,
                ownershipPercent: 61.4
            )
        )

        #expect(response.symbol == "AAPL")
        #expect(response.asOfQuarter == "2026Q2")
        #expect(response.holdersCount == 4821)
        #expect(response.totalShares == 9_500_000)
        #expect(response.institutionalOwnershipPct == 61.4)
        #expect(response.topHolders.count == 1)
    }

    @Test("Holders without a summary still answer, with the totals null")
    func holdersWithoutASummaryStillAnswer() {
        let response = InstitutionalOwnership.build(
            symbol: "AAPL",
            quarter: MarketQuarter(year: 2026, quarter: 2),
            wireHolders: [holder(name: "Fund A", shares: 100)],
            summary: nil
        )

        #expect(response.holdersCount == nil)
        #expect(response.totalShares == nil)
        #expect(response.institutionalOwnershipPct == nil)
        #expect(response.topHolders.map(\.name) == ["Fund A"])
    }

    @Test("A summary without holders still answers, with an empty holder list")
    func aSummaryWithoutHoldersStillAnswers() {
        let response = InstitutionalOwnership.build(
            symbol: "AAPL",
            quarter: MarketQuarter(year: 2026, quarter: 1),
            wireHolders: [],
            summary: FMPInstitutionalPositionsSummary(
                symbol: "AAPL",
                date: nil,
                investorsHolding: 12,
                numberOf13Fshares: nil,
                ownershipPercent: nil
            )
        )

        #expect(response.asOfQuarter == "2026Q1")
        #expect(response.holdersCount == 12)
        #expect(response.totalShares == nil)
        #expect(response.topHolders.isEmpty)
    }

    @Test("The cache key names the symbol")
    func cacheKeyNamesTheSymbol() {
        #expect(InstitutionalOwnership.redisKey("AAPL") == "market:institutional:AAPL")
    }
}
