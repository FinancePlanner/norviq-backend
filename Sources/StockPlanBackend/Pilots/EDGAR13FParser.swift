import Foundation
import Vapor
#if canImport(FoundationXML)
    import FoundationXML
#endif

struct EDGARFilingRef: Sendable, Equatable {
    let accession: String
    /// `yyyy-MM-dd`, the quarter end the filing reports.
    let reportDate: String

    /// `2026-06-30` → `2026Q2`.
    var period: String {
        let parts = reportDate.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return reportDate }
        return "\(parts[0])Q\((month - 1) / 3 + 1)"
    }
}

struct EDGAR13FHolding: Sendable, Equatable {
    let cusip: String
    /// US dollars (EDGAR reports whole dollars since 2023-01-03).
    let value: Double
    let shares: Double
}

/// Pure parsing of the three EDGAR documents a 13F lookup needs.
enum EDGAR13FParser {
    private struct Submissions: Decodable {
        struct Filings: Decodable { let recent: Recent }
        struct Recent: Decodable {
            let form: [String]
            let accessionNumber: [String]
            let reportDate: [String]
        }

        let filings: Filings
    }

    private struct Index: Decodable {
        struct Directory: Decodable { let item: [Item] }
        struct Item: Decodable { let name: String }
        let directory: Directory
    }

    /// The newest original 13F-HR. Amendments (13F-HR/A) are ignored in v1:
    /// many restate only part of a filing, and reading one as the whole book
    /// would empty positions the fund still holds.
    static func latest13F(submissions: Data) throws -> EDGARFilingRef? {
        let recent = try JSONDecoder().decode(Submissions.self, from: submissions).filings.recent
        for i in recent.form.indices where recent.form[i] == "13F-HR" {
            guard i < recent.accessionNumber.count, i < recent.reportDate.count else { continue }
            return EDGARFilingRef(accession: recent.accessionNumber[i], reportDate: recent.reportDate[i])
        }
        return nil
    }

    static func infoTableName(index: Data) throws -> String? {
        try JSONDecoder().decode(Index.self, from: index).directory.item
            .map(\.name)
            .first { $0.lowercased().hasSuffix(".xml") && $0.lowercased() != "primary_doc.xml" }
    }

    /// Share positions only: rows with `putCall` (options) or a `PRN`
    /// (principal amount, i.e. debt) type are skipped. Funds often split one
    /// security across several rows by manager; those are summed per CUSIP.
    static func holdings(infoTable: Data) throws -> [EDGAR13FHolding] {
        let delegate = InfoTableDelegate()
        let parser = XMLParser(data: infoTable)
        parser.delegate = delegate
        guard parser.parse() else {
            throw Abort(.badGateway, reason: "EDGAR information table did not parse: \(parser.parserError.map(String.init(describing:)) ?? "unknown")")
        }
        var totals: [String: (value: Double, shares: Double)] = [:]
        var order: [String] = []
        for row in delegate.rows where row.putCall == nil && row.type == "SH" {
            guard let value = Double(row.value), let shares = Double(row.shares), value > 0, shares > 0 else { continue }
            if totals[row.cusip] == nil {
                order.append(row.cusip)
            }
            totals[row.cusip, default: (0, 0)].value += value
            totals[row.cusip, default: (0, 0)].shares += shares
        }
        return order.map { EDGAR13FHolding(cusip: $0, value: totals[$0]!.value, shares: totals[$0]!.shares) }
    }
}

private final class InfoTableDelegate: NSObject, XMLParserDelegate {
    struct Row {
        var cusip = ""
        var value = ""
        var shares = ""
        var type = ""
        var putCall: String?
    }

    private(set) var rows: [Row] = []
    private var current: Row?
    private var text = ""

    /// `ns1:infoTable` → `infoTable`. EDGAR files use both prefixed and bare names.
    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        if local(elementName) == "infoTable" {
            current = Row()
        }
        text = ""
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(elementName) {
        case "cusip": current?.cusip = value.uppercased()
        case "value": current?.value = value
        case "sshPrnamt": current?.shares = value
        case "sshPrnamtType": current?.type = value.uppercased()
        case "putCall": current?.putCall = value.isEmpty ? nil : value
        case "infoTable":
            if let row = current {
                rows.append(row)
            }
            current = nil
        default: break
        }
        text = ""
    }
}
