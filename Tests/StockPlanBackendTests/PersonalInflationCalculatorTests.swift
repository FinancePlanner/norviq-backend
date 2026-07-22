import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Personal inflation calculator")
struct PersonalInflationCalculatorTests {
    @Test("weights mapped spending and reports unmapped coverage")
    func weightedRateAndCoverage() throws {
        let formatter = FOMCCalendar.dayFormatter
        let start = try #require(formatter.date(from: "2025-07-01"))
        let end = try #require(formatter.date(from: "2026-07-01"))
        let snapshot = makeSnapshot(components: [
            InflationComponentDTO(category: "Food at Home", ourYoY: 4),
            InflationComponentDTO(category: "Shelter: Rent", ourYoY: 2),
        ])

        let response = PersonalInflationCalculator.calculate(
            expenses: [
                .init(category: "Groceries", title: "Market", amount: 600),
                .init(category: "Rent", title: "July rent", amount: 400),
                .init(category: "Savings", title: "Emergency fund", amount: 1000),
            ],
            snapshot: snapshot,
            country: .us,
            periodMonths: 12,
            sampleStart: start,
            sampleEnd: end
        )

        #expect(response.personalRate == 3.2)
        #expect(response.officialRate == 3)
        #expect(response.difference == 0.2)
        #expect(response.coveragePercent == 50)
        #expect(response.totalSpend == 2000)
        #expect(response.mappedSpend == 1000)
        #expect(response.components.map(\.category) == ["Groceries", "Rent"])
    }

    @Test("shared-user amount is supplied by the service, calculator rejects no categories")
    func noMappedCategories() throws {
        let formatter = FOMCCalendar.dayFormatter
        let date = try #require(formatter.date(from: "2026-07-01"))
        let response = PersonalInflationCalculator.calculate(
            expenses: [.init(category: "Investments", title: "Broker transfer", amount: 500)],
            snapshot: makeSnapshot(components: []),
            country: .us,
            periodMonths: 6,
            sampleStart: date,
            sampleEnd: date
        )

        #expect(response.personalRate == nil)
        #expect(response.estimatedAnnualImpact == nil)
        #expect(response.coveragePercent == 0)
    }

    private func makeSnapshot(components: [InflationComponentDTO]) -> InflationSnapshotResponse {
        InflationSnapshotResponse(
            country: "US",
            currency: "USD",
            asOf: "2026-06-01",
            updatedAt: "2026-07-01T00:00:00Z",
            source: "BLS via FRED",
            headline: InflationGaugeDTO(name: "CPI", nowValue: 3),
            gauges: [],
            components: components,
            topMovers: []
        )
    }
}
