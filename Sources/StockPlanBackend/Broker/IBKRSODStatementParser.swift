import Foundation

/// Provisional SOD statement interpretation.
///
/// **Do not treat field aliases as final IBKR file-layout.** When live fixtures arrive,
/// lock column maps to IBKR docs and replace these aliases.
struct IBKRSODStatementParser: Sendable {
    struct ParsedStatement: Sendable, Equatable {
        var reportDate: String
        var fileSummaries: [FileSummary]
        var provisionalPositions: [ProvisionalPosition]
        var provisionalActivities: [ProvisionalActivity]
    }

    struct FileSummary: Sendable, Equatable {
        var fileName: String
        var sectionNames: [String]
        var sectionCount: Int
        var dataRowCount: Int
    }

    /// Provisional only — aliases may not match production SOD columns.
    struct ProvisionalPosition: Sendable, Equatable {
        var symbol: String
        var quantity: Double?
        var raw: [String: String]
        var section: String
    }

    struct ProvisionalActivity: Sendable, Equatable {
        var symbol: String?
        var quantity: Double?
        var raw: [String: String]
        var section: String
    }

    private let htParser = IBKRSODHTCSVParser()

    func parse(fetch: IBKRSODFetchResult) throws -> ParsedStatement {
        var summaries: [FileSummary] = []
        var positions: [ProvisionalPosition] = []
        var activities: [ProvisionalActivity] = []

        for file in fetch.files {
            let document = try htParser.parse(file.csvText)
            let dataRows = document.sections.reduce(0) { $0 + $1.rows.count }
            summaries.append(
                FileSummary(
                    fileName: file.name,
                    sectionNames: document.sections.map(\.name),
                    sectionCount: document.sections.count,
                    dataRowCount: dataRows
                )
            )

            for section in document.sections {
                let kind = classifySection(section.name)
                switch kind {
                case .position:
                    for row in section.rows {
                        if let symbol = firstValue(in: row, aliases: Self.symbolAliases) {
                            positions.append(
                                ProvisionalPosition(
                                    symbol: symbol.uppercased(),
                                    quantity: firstDouble(in: row, aliases: Self.quantityAliases),
                                    raw: row,
                                    section: section.name
                                )
                            )
                        }
                    }
                case .activity:
                    for row in section.rows {
                        activities.append(
                            ProvisionalActivity(
                                symbol: firstValue(in: row, aliases: Self.symbolAliases)?.uppercased(),
                                quantity: firstDouble(in: row, aliases: Self.quantityAliases),
                                raw: row,
                                section: section.name
                            )
                        )
                    }
                case .other:
                    continue
                }
            }
        }

        return ParsedStatement(
            reportDate: fetch.reportDate,
            fileSummaries: summaries,
            provisionalPositions: positions,
            provisionalActivities: activities
        )
    }

    enum SectionKind {
        case position
        case activity
        case other
    }

    func classifySection(_ name: String) -> SectionKind {
        let normalized = name.lowercased()
        if normalized.contains("position") || normalized == "post" || normalized == "poss" {
            return .position
        }
        if normalized.contains("activity")
            || normalized.contains("trade")
            || normalized == "trnt"
            || normalized == "trns"
        {
            return .activity
        }
        return .other
    }

    // MARK: - Provisional aliases (replace with locked IBKR layout)

    static let symbolAliases = ["symbol", "ticker", "underlying", "underlyingSymbol", "sym"]
    static let quantityAliases = ["quantity", "qty", "position", "shares", "share"]

    private func firstValue(in row: [String: String], aliases: [String]) -> String? {
        let normalizedAliases = Set(aliases.map { IBKRSODHTCSVParser.normalizeHeader($0) })
        for (key, value) in row {
            if normalizedAliases.contains(key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstDouble(in row: [String: String], aliases: [String]) -> Double? {
        guard let raw = firstValue(in: row, aliases: aliases) else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }
}
