import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Portfolio reporting and retirement", .serialized)
struct PortfolioReportingTests {
    @Test("Portfolio and reporting migrations apply and revert")
    func migrationsApplyAndRevert() async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                #expect(try await AdvancedReportTemplateRecord.query(on: app.db).count() == 0)
                #expect(try await PortfolioMembershipRecord.query(on: app.db).count() == 0)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Weekly recurrence uses the requested weekday and local time")
    func weeklyRecurrence() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-07-13T12:00:00Z"))
        let recurrence = ReportRecurrence(
            frequency: .weekly,
            timeZone: "UTC",
            localTime: "09:30",
            weekday: .wednesday
        )

        let next = try ReportRecurrenceCalculator().next(after: start, recurrence: recurrence)

        #expect(ISO8601DateFormatter().string(from: next) == "2026-07-15T09:30:00Z")
    }

    @Test("Monthly recurrence clamps to the final day of a short month")
    func monthlyRecurrenceClampsDay() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2027-01-31T20:00:00Z"))
        let recurrence = ReportRecurrence(
            frequency: .monthly,
            timeZone: "UTC",
            localTime: "08:00",
            dayOfMonth: 31
        )

        let next = try ReportRecurrenceCalculator().next(after: start, recurrence: recurrence)

        #expect(ISO8601DateFormatter().string(from: next) == "2027-02-28T08:00:00Z")
    }

    @Test("Signed report links are scoped to the artifact and recipient")
    func signedReportLinks() {
        let signer = ReportDownloadSigner(secret: "a-test-secret-with-more-than-thirty-two-characters")
        let artifactId = UUID()
        let recipientId = UUID()
        let expiry = Date().addingTimeInterval(600)
        let signature = signer.signature(
            artifactId: artifactId,
            expiresAt: expiry,
            recipientUserId: recipientId
        )

        #expect(signer.verify(
            signature: signature,
            artifactId: artifactId,
            expiresAt: expiry,
            recipientUserId: recipientId
        ))
        #expect(signer.verify(
            signature: signature,
            artifactId: UUID(),
            expiresAt: expiry,
            recipientUserId: recipientId
        ) == false)
        #expect(signer.verify(
            signature: signature,
            artifactId: artifactId,
            expiresAt: expiry,
            recipientUserId: UUID()
        ) == false)
    }

    @Test("Workbook contains the expected sheets, formulas, and escaped values")
    func workbookStructure() {
        let document = reportDocument(title: "Family & Retirement <2026>")

        let workbook = SimpleXLSXWriter().makeWorkbook(document)

        #expect(workbook.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #expect(workbook.range(of: Data("xl/worksheets/sheet1.xml".utf8)) != nil)
        #expect(workbook.range(of: Data("<f>SUM(C4:D4)</f>".utf8)) != nil)
        #expect(workbook.range(of: Data("Family &amp; Retirement &lt;2026&gt;".utf8)) != nil)
        #expect(workbook.range(of: Data("Assumptions and disclosures".utf8)) != nil)
    }

    @Test("Rendering fixture can be emitted for visual acceptance")
    func renderingFixture() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["REPORT_VISUAL_OUTPUT_PATH"] else { return }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = reportDocument(title: "Family & Retirement Review")
        try Data(ReportHTMLRenderer().render(document).utf8)
            .write(to: directory.appendingPathComponent("advanced-report.html"), options: .atomic)
        try SimpleXLSXWriter().makeWorkbook(document)
            .write(to: directory.appendingPathComponent("advanced-report.xlsx"), options: .atomic)
    }

    @Test("Report HTML escapes user-authored content")
    func reportHTMLEscaping() {
        let document = reportDocument(title: "<script>alert('x')</script>")

        let html = ReportHTMLRenderer().render(document)

        #expect(html.contains("&lt;script&gt;alert('x')&lt;/script&gt;"))
        #expect(html.contains("<script>alert('x')</script>") == false)
    }

    @Test("Retirement projections are deterministic for a fixed seed")
    func retirementProjectionIsDeterministic() throws {
        let input = RetirementPlanInput(
            jurisdiction: .unitedStates,
            currency: "USD",
            currentAge: 40,
            retirementAge: 65,
            longevityAge: 90,
            annualSalary: 120_000,
            annualSalaryGrowthRate: 0.02,
            desiredAnnualSpending: 55000,
            inflationRate: 0.02,
            expectedAnnualReturn: 0.06,
            annualVolatility: 0.12,
            annualContributionGrowthRate: 0.02,
            withdrawalStrategy: .fixedRealSpending,
            accounts: [
                .init(
                    id: "401k",
                    name: "401(k)",
                    wrapper: .us401k,
                    currentBalance: 250_000,
                    employeeAnnualContribution: 20000,
                    employerMatch: .init(matchRate: 0.5, upToSalaryPercent: 0.06)
                ),
            ],
            publicPension: .init(
                annualAmount: 24000,
                startAge: 67,
                annualIndexationRate: 0.02,
                currency: "USD"
            )
        )
        let request = RetirementProjectionRequest(pathCount: 200, seed: 1234)
        let engine = RetirementProjectionEngine(rules: RetirementRuleRegistry())
        let portfolioId = UUID()

        let first = try engine.project(portfolioId: portfolioId, input: input, request: request)
        let second = try engine.project(portfolioId: portfolioId, input: input, request: request)

        #expect(first.summary == second.summary)
        #expect(first.points == second.points)
        #expect(first.points.count == 51)
        #expect(first.summary.annualContributionHeadroom == 4500)
    }

    private func reportDocument(title: String) -> ReportDocument {
        let portfolioId = UUID()
        let template = ReportTemplateInput(
            name: title,
            description: "Quarterly review",
            blocks: [
                .init(id: "holdings", kind: .holdings, title: "Holdings", portfolioIds: [portfolioId.uuidString]),
            ]
        )
        return ReportDocument(
            title: title,
            description: "Quarterly review",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            template: template,
            portfolios: [
                .init(
                    id: portfolioId,
                    name: "Joint portfolio",
                    currency: "USD",
                    holdings: [
                        .init(symbol: "ACME", shares: 10, price: 12.5, value: 125, category: "stock"),
                    ],
                    cash: 25
                ),
            ]
        )
    }
}
