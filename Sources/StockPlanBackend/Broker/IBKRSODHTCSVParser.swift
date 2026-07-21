import Foundation
import Vapor

/// Splits IBKR H/T (header/trailer) CSV text into typed sections without inventing column semantics.
///
/// Supports common IBKR machine-readable layouts:
/// - Line discriminator `H` / `T` file markers
/// - Section markers `BOS` / `EOS` (begin/end section) with `HEADER` + `DATA` rows
/// - Flex-style `Section,Header|Data,...` two-column discriminators
///
/// Column meaning for Position/Activity ingest is provisional until live SOD fixtures arrive.
struct IBKRSODHTCSVParser: Sendable {
    struct Section: Sendable, Equatable {
        var name: String
        var headers: [String]
        var rows: [[String: String]]
    }

    struct Document: Sendable, Equatable {
        var sections: [Section]
        var rawLineCount: Int
    }

    func parse(_ csvText: String) throws -> Document {
        let lines = csvText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw IBKRSODParseError.empty
        }

        // Prefer Flex-style Section,Header/Data layout when detected.
        if looksLikeFlexStyle(lines) {
            return parseFlexStyle(lines)
        }
        return parseDiscriminatedStyle(lines)
    }

    private func looksLikeFlexStyle(_ lines: [String]) -> Bool {
        guard let first = lines.first else { return false }
        let fields = Self.splitCSVLine(first)
        guard fields.count >= 2 else { return false }
        let kind = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kind == "header" || kind == "data" || kind == "bos" || kind == "eos"
    }

    private func parseFlexStyle(_ lines: [String]) -> Document {
        var sections: [Section] = []
        var currentName = "Unknown"
        var headers: [String] = []
        var rows: [[String: String]] = []

        func flush() {
            guard !headers.isEmpty || !rows.isEmpty else { return }
            sections.append(Section(name: currentName, headers: headers, rows: rows))
            headers = []
            rows = []
        }

        for line in lines {
            let fields = Self.splitCSVLine(line)
            guard fields.count >= 2 else { continue }
            let section = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let values = Array(fields.dropFirst(2))

            switch kind {
            case "header":
                if section != currentName, !headers.isEmpty || !rows.isEmpty {
                    flush()
                }
                currentName = section.isEmpty ? currentName : section
                headers = values.map(Self.normalizeHeader)
            case "data":
                if section != currentName, !section.isEmpty, !headers.isEmpty || !rows.isEmpty {
                    flush()
                    currentName = section
                }
                rows.append(Self.rowDictionary(headers: headers, values: values))
            case "bos":
                flush()
                currentName = values.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? section.nilIfEmpty
                    ?? currentName
            case "eos", "eoa", "eof", "boa", "bof":
                flush()
            default:
                continue
            }
        }
        flush()
        return Document(sections: sections, rawLineCount: lines.count)
    }

    private func parseDiscriminatedStyle(_ lines: [String]) -> Document {
        var sections: [Section] = []
        var currentName = "File"
        var headers: [String] = []
        var rows: [[String: String]] = []

        func flush() {
            guard !headers.isEmpty || !rows.isEmpty else { return }
            sections.append(Section(name: currentName, headers: headers, rows: rows))
            headers = []
            rows = []
        }

        for line in lines {
            let fields = Self.splitCSVLine(line)
            guard let first = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let upper = first.uppercased()

            if upper == "H" || upper == "T" {
                // File-level header/trailer — capture type hint if present.
                if fields.count > 1 {
                    let hint = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hint.isEmpty {
                        currentName = hint
                    }
                }
                continue
            }
            if upper == "BOS" {
                flush()
                currentName = fields.dropFirst().first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? currentName
                continue
            }
            if upper == "EOS" || upper == "EOF" || upper == "EOA" {
                flush()
                continue
            }
            if upper == "HEADER" {
                headers = fields.dropFirst().map(Self.normalizeHeader)
                continue
            }
            if upper == "DATA" {
                rows.append(Self.rowDictionary(headers: headers, values: Array(fields.dropFirst())))
                continue
            }

            // Plain CSV fallback: first non-empty line as header, rest as data.
            if headers.isEmpty {
                headers = fields.map(Self.normalizeHeader)
            } else {
                rows.append(Self.rowDictionary(headers: headers, values: fields))
            }
        }
        flush()
        return Document(sections: sections, rawLineCount: lines.count)
    }

    static func splitCSVLine(_ line: String, delimiter: Character = ",") -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" {
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
            if ch == delimiter, !inQuotes {
                fields.append(current)
                current = ""
                index = line.index(after: index)
                continue
            }
            current.append(ch)
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    static func normalizeHeader(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    static func rowDictionary(headers: [String], values: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (idx, header) in headers.enumerated() where !header.isEmpty {
            let value = idx < values.count ? values[idx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            out[header] = value
        }
        return out
    }
}

enum IBKRSODParseError: Error, Equatable {
    case empty
}

extension IBKRSODParseError: AbortError {
    var status: HTTPResponseStatus {
        .badRequest
    }

    var reason: String {
        switch self {
        case .empty:
            "IBKR statement CSV is empty."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
