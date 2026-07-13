import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Tax reliability policies")
struct TaxReliabilityPolicyTests {
    @Test
    func `Spain market window requires documentary verification`() {
        #expect(SpainMarketAdmissionPolicy.windowMonths(
            status: "unlisted",
            source: nil,
            reviewedAt: nil
        ) == nil)
        #expect(SpainMarketAdmissionPolicy.windowMonths(
            status: "regulated",
            source: "user_verified_document",
            reviewedAt: nil
        ) == nil)
    }

    @Test
    func `Spain verified admission selects the statutory window`() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SpainMarketAdmissionPolicy.windowMonths(
            status: "regulated",
            source: "user_verified_document",
            reviewedAt: reviewedAt
        ) == 2)
        #expect(SpainMarketAdmissionPolicy.windowMonths(
            status: "unlisted",
            source: "user_verified_document",
            reviewedAt: reviewedAt
        ) == 12)
        #expect(SpainMarketAdmissionPolicy.windowMonths(
            status: "unknown",
            source: "user_verified_document",
            reviewedAt: reviewedAt
        ) == nil)
    }

    @Test
    func `report retries back off and cap at one hour`() {
        #expect(TaxReportGenerationPoller.retryDelaySeconds(for: 1) == 30)
        #expect(TaxReportGenerationPoller.retryDelaySeconds(for: 2) == 60)
        #expect(TaxReportGenerationPoller.retryDelaySeconds(for: 5) == 480)
        #expect(TaxReportGenerationPoller.retryDelaySeconds(for: 20) == 3600)
    }
}
