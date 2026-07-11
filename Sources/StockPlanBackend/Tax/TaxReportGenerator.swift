import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxReportGenerator: Sendable {
    func generate(reportID: UUID, application: Application) async {
        do {
            guard let report = try await TaxReport.find(reportID, on: application.db) else { return }
            guard let profile = try await TaxProfile.query(on: application.db)
                .filter(\.$userId == report.userId)
                .filter(\.$taxYear == report.taxYear)
                .first(),
                let jurisdiction = TaxJurisdiction(rawValue: profile.jurisdiction)
            else { throw Abort(.unprocessableEntity, reason: "A completed tax profile is required.") }

            let dashboard = try await application.taxService.dashboard(
                userId: report.userId,
                jurisdiction: jurisdiction,
                taxYear: report.taxYear,
                on: application.db
            )
            let directory = application.directory.workingDirectory
                + ".build/tax-reports/\(report.userId.uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = "\(directory)/\(reportID.uuidString).\(report.format)"
            if report.format == TaxReportFormat.csv.rawValue {
                try csvData(dashboard).write(to: URL(fileURLWithPath: path), options: .atomic)
            } else {
                try simplePDFData(dashboard).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            report.status = "ready"
            report.filePath = path
            report.expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: Date())
            report.errorMessage = nil
            try await report.save(on: application.db)
        } catch {
            application.logger.error("tax.report generation failed report_id=\(reportID) error=\(error)")
            if let report = try? await TaxReport.find(reportID, on: application.db) {
                report.status = "failed"
                report.errorMessage = "Report generation failed."
                try? await report.save(on: application.db)
            }
        }
    }

    private func csvData(_ dashboard: TaxDashboardResponse) -> Data {
        var rows = [
            "symbol,instrumentType,accountId,quantity,marketValue,unrealizedLoss,estimatedTaxBenefit,holdingPeriod,status,supportLevel,warnings",
        ]
        rows += dashboard.opportunities.map { opportunity in
            [
                opportunity.symbol,
                opportunity.instrumentType,
                opportunity.accountId,
                NSDecimalNumber(decimal: opportunity.eligibleQuantity).stringValue,
                NSDecimalNumber(decimal: opportunity.marketValue.amount).stringValue,
                NSDecimalNumber(decimal: opportunity.unrealizedLoss.amount).stringValue,
                NSDecimalNumber(decimal: opportunity.estimatedTaxBenefit.amount).stringValue,
                opportunity.holdingPeriod,
                opportunity.status.rawValue,
                opportunity.supportLevel.rawValue,
                opportunity.warnings.joined(separator: "; "),
            ].map(csvEscape).joined(separator: ",")
        }
        rows.append("")
        rows.append(csvEscape("Advisor workpaper only. \(dashboard.disclaimer)"))
        return Data((["\u{FEFF}"] + rows).joined(separator: "\n").utf8)
    }

    private func simplePDFData(_ dashboard: TaxDashboardResponse) -> Data {
        let currency = dashboard.summary.estimatedNetBenefit.currency
        let lines = [
            "Norviq Tax Optimization Workpaper",
            "Jurisdiction: \(dashboard.jurisdiction.rawValue)   Tax year: \(dashboard.taxYear)",
            "Rule version: \(dashboard.ruleVersion)",
            "Estimated realized liability: \(money(dashboard.summary.realizedEstimatedLiability.amount)) \(currency)",
            "Embedded unrealized liability: \(money(dashboard.summary.embeddedUnrealizedLiability.amount)) \(currency)",
            "Harvestable losses: \(money(dashboard.summary.harvestableLosses.amount)) \(currency)",
            "Estimated net benefit: \(money(dashboard.summary.estimatedNetBenefit.amount)) \(currency)",
            "Opportunities: \(dashboard.opportunities.count)",
            "",
            "Advisor workpaper only. Not filing-ready.",
            dashboard.disclaimer,
        ]
        return MinimalPDF.make(lines: lines)
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum MinimalPDF {
    static func make(lines: [String]) -> Data {
        let content = contentStream(lines)
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private static func contentStream(_ lines: [String]) -> String {
        var stream = "BT\n/F1 16 Tf\n50 740 Td\n"
        for (index, line) in lines.enumerated() {
            if index > 0 {
                stream += "0 -24 Td\n"
            }
            stream += "(\(escape(line))) Tj\n"
        }
        return stream + "ET"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .unicodeScalars
            .map { $0.isASCII ? String($0) : "?" }
            .joined()
    }
}

extension Application {
    private struct TaxReportGeneratorKey: StorageKey {
        typealias Value = TaxReportGenerator
    }

    var taxReportGenerator: TaxReportGenerator {
        get { storage[TaxReportGeneratorKey.self] ?? TaxReportGenerator() }
        set { storage[TaxReportGeneratorKey.self] = newValue }
    }
}
