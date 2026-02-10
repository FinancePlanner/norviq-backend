import Foundation
import Vapor

enum CsvImportServiceError: Error {
    case emptyBody
    case missingHeader
    case missingSymbolColumn
}

extension CsvImportServiceError: AbortError {
    var status: HTTPResponseStatus { .badRequest }

    var reason: String {
        switch self {
        case .emptyBody:
            return "CSV body is empty."
        case .missingHeader:
            return "CSV must include a header row."
        case .missingSymbolColumn:
            return "CSV header must include a symbol column (symbol/ticker)."
        }
    }
}

struct CsvImportService: Sendable {
    func preview(csv raw: String, provider: String) throws -> CsvImportPreviewResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CsvImportServiceError.emptyBody
        }

        let allLines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !allLines.isEmpty else {
            throw CsvImportServiceError.emptyBody
        }

        var lineIndex = 0
        if allLines.first?.lowercased().hasPrefix("sep=") == true {
            lineIndex = 1
        }

        guard lineIndex < allLines.count else {
            throw CsvImportServiceError.missingHeader
        }

        let headerLine = allLines[lineIndex]
        let delimiter = Self.inferDelimiter(from: headerLine)
        let headerFields = Self.splitCSVLine(headerLine, delimiter: delimiter).map(Self.normalizeHeaderField)

        guard let symbolIndex = Self.firstIndex(in: headerFields, matchingAny: Self.symbolHeaderAliases) else {
            throw CsvImportServiceError.missingSymbolColumn
        }

        let sharesIndex = Self.firstIndex(in: headerFields, matchingAny: Self.sharesHeaderAliases)
        let buyPriceIndex = Self.firstIndex(in: headerFields, matchingAny: Self.buyPriceHeaderAliases)
        let buyDateIndex = Self.firstIndex(in: headerFields, matchingAny: Self.buyDateHeaderAliases)
        let notesIndex = Self.firstIndex(in: headerFields, matchingAny: Self.notesHeaderAliases)

        var items: [CsvImportPreviewItem] = []
        var errors: [CsvImportPreviewError] = []

        let dataLines = allLines.dropFirst(lineIndex + 1)
        for (offset, rawLine) in dataLines.enumerated() {
            let csvLineNumber = (lineIndex + 2) + offset
            let fields = Self.splitCSVLine(rawLine, delimiter: delimiter)

            let rawSymbol = Self.field(at: symbolIndex, in: fields)
            let symbol = rawSymbol
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            guard !symbol.isEmpty else {
                errors.append(.init(line: csvLineNumber, message: "Missing symbol."))
                continue
            }

            let shares = Self.parseDouble(Self.field(at: sharesIndex, in: fields))
            let buyPrice = Self.parseDouble(Self.field(at: buyPriceIndex, in: fields))
            let buyDate = Self.parseOptionalString(Self.field(at: buyDateIndex, in: fields))
            let notes = Self.parseOptionalString(Self.field(at: notesIndex, in: fields))

            items.append(
                .init(
                    line: csvLineNumber,
                    symbol: symbol,
                    shares: shares,
                    buyPrice: buyPrice,
                    buyDate: buyDate,
                    notes: notes
                )
            )
        }

        return .init(provider: provider, items: items, errors: errors)
    }
}

extension CsvImportService {
    private static let symbolHeaderAliases: Set<String> = ["symbol", "ticker", "sym"]
    private static let sharesHeaderAliases: Set<String> = ["shares", "share", "quantity", "qty"]
    private static let buyPriceHeaderAliases: Set<String> = ["buyprice", "averagecost", "avgcost", "costbasis", "purchaseprice"]
    private static let buyDateHeaderAliases: Set<String> = ["buydate", "purchasedate", "purchase", "opened", "opendate"]
    private static let notesHeaderAliases: Set<String> = ["notes", "note", "memo", "comment", "comments"]

    private static func inferDelimiter(from headerLine: String) -> Character {
        if headerLine.contains("\t"), !headerLine.contains(",") {
            return "\t"
        }
        if headerLine.contains(";"), !headerLine.contains(",") {
            return ";"
        }
        return ","
    }

    private static func normalizeHeaderField(_ raw: String) -> String {
        let withoutBOM = raw.replacingOccurrences(of: "\u{feff}", with: "")
        let alnum = withoutBOM.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(alnum)).lowercased()
    }

    private static func firstIndex(in headers: [String], matchingAny aliases: Set<String>) -> Int? {
        for (index, header) in headers.enumerated() {
            if aliases.contains(header) {
                return index
            }
        }
        return nil
    }

    private static func field(at index: Int?, in fields: [String]) -> String {
        guard let index, index >= 0, index < fields.count else {
            return ""
        }
        return fields[index]
    }

    private static func parseOptionalString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    static func normalizeDateOnlyString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dateOnly = trimmed.split(whereSeparator: { $0 == "T" || $0 == " " }).first.map(String.init) ?? trimmed

        if dateOnly.count == 10, dateOnly[dateOnly.index(dateOnly.startIndex, offsetBy: 4)] == "-" {
            if let date = parseDate(dateOnly, format: "yyyy-MM-dd") {
                return formatISODateOnly(date)
            }
        }

        for format in ["yyyy/MM/dd", "MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy", "M-d-yyyy"] {
            if let date = parseDate(dateOnly, format: format) {
                return formatISODateOnly(date)
            }
        }

        if dateOnly.count == 8, let date = parseYYYYMMDD(dateOnly) {
            return formatISODateOnly(date)
        }

        return nil
    }

    private static func parseDate(_ raw: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.date(from: raw)
    }

    private static func parseYYYYMMDD(_ raw: String) -> Date? {
        guard raw.count == 8 else { return nil }
        let year = raw.prefix(4)
        let month = raw.dropFirst(4).prefix(2)
        let day = raw.suffix(2)
        return parseDate("\(year)-\(month)-\(day)", format: "yyyy-MM-dd")
    }

    private static func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]

            if char == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                index = next
                continue
            }

            if char == delimiter, !inQuotes {
                fields.append(current)
                current = ""
                index = line.index(after: index)
                continue
            }

            current.append(char)
            index = line.index(after: index)
        }

        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
