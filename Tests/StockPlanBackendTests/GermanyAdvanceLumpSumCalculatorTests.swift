@testable import StockPlanBackend
import Testing

@Suite("Germany advance lump sum calculator")
struct GermanyAdvanceLumpSumCalculatorTests {
    @Test("uses the published 2026 basis rate and equity-fund exemption")
    func calculatesEquityFundAmount() throws {
        let result = try GermanyAdvanceLumpSumCalculator.calculate(.init(
            calculationYear: 2026,
            beginningMarketValue: 100_000,
            endingMarketValue: 108_000,
            distributions: 500,
            acquisitionMonth: nil,
            fundClassification: .equity
        ))

        #expect(result.basisRate == 0.032)
        #expect(result.baseYield == 2240)
        #expect(result.grossAdvanceLumpSum == 1740)
        #expect(result.taxableAdvanceLumpSum == 1218)
        #expect(result.deemedReceiptTaxYear == 2027)
    }

    @Test("caps the amount by annual appreciation")
    func capsByAppreciation() throws {
        let result = try GermanyAdvanceLumpSumCalculator.calculate(.init(
            calculationYear: 2025,
            beginningMarketValue: 100_000,
            endingMarketValue: 100_400,
            distributions: 100,
            acquisitionMonth: nil,
            fundClassification: .other
        ))

        #expect(result.appreciationCap == 500)
        #expect(result.grossAdvanceLumpSum == 400)
    }

    @Test("prorates an acquisition made during the year")
    func proratesAcquisitionYear() throws {
        let result = try GermanyAdvanceLumpSumCalculator.calculate(.init(
            calculationYear: 2026,
            beginningMarketValue: 12000,
            endingMarketValue: 13000,
            distributions: 0,
            acquisitionMonth: 10,
            fundClassification: .mixed
        ))

        #expect(result.acquisitionYearFactor == 0.25)
        #expect(result.grossAdvanceLumpSum == 67.2)
        #expect(result.taxableAdvanceLumpSum == 57.12)
    }

    @Test("rejects years without an official configured rate")
    func rejectsUnsupportedYear() {
        #expect(throws: GermanyAdvanceLumpSumError.unsupportedCalculationYear(2024)) {
            try GermanyAdvanceLumpSumCalculator.calculate(.init(
                calculationYear: 2024,
                beginningMarketValue: 1000,
                endingMarketValue: 1100,
                distributions: 0,
                acquisitionMonth: nil,
                fundClassification: .equity
            ))
        }
    }
}
