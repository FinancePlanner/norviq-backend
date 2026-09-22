import Foundation

/// A due-diligence ask pulled out of a chat message.
///
/// Ordinary turns never enter this path. A stance phrase such as "should I sell"
/// counts only when a ticker is in the same message, so "what's my budget" and
/// a bare "should I sell" stay with the normal assistant.
struct PositionMemoAsk: Equatable, Sendable {
    var askedSymbol: String
    var companionSymbol: String?
    var cost: Double?
    var costCurrency: String?
    /// Signed. "down 34%" is `-34`.
    var statedPercent: Double?

    static func parse(_ raw: String) -> PositionMemoAsk? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let symbols = extractSymbols(text)
        guard isMemo(text, hasTicker: symbols.asked != nil), let asked = symbols.asked else { return nil }
        let cost = extractCost(text)
        return PositionMemoAsk(
            askedSymbol: asked,
            companionSymbol: symbols.companion,
            cost: cost?.amount,
            costCurrency: cost?.currency,
            statedPercent: extractStatedPercent(text)
        )
    }

    private static func isMemo(_ text: String, hasTicker: Bool) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if folded.range(of: #"(?i)(?:^|\s)/dd(?:\s|$)"#, options: .regularExpression) != nil {
            return true
        }
        if folded.contains("due diligence") {
            return true
        }
        if folded.range(of: #"(?i)\bmake\s+(?:a\s+)?dd\b"#, options: .regularExpression) != nil {
            return true
        }
        if folded.contains("write a memo") || folded.contains("write me a memo") || folded.contains("position memo") {
            return true
        }
        let stance = folded.contains("should i sell") || folded.contains("should i hold") || folded.contains("average down")
        return stance && hasTicker
    }

    private struct Symbols {
        var asked: String?
        var companion: String?
    }

    private static func extractSymbols(_ text: String) -> Symbols {
        let parenthetical = matches(text, pattern: #"\(([A-Za-z][A-Za-z0-9]{0,5}(?:\.[A-Za-z]{1,3})?)\)"#)
            .map(normalizeTicker)
            .filter(isTicker)
        let dollar = matches(text, pattern: #"\$([A-Za-z][A-Za-z0-9]{0,5}(?:\.[A-Za-z]{1,4})?)"#)
            .map(normalizeTicker)
            .filter(isTicker)
        let contextual = matches(text, pattern: #"(?i)\b(?:about|on|for|sell|hold)\s+(?:my\s+)?\$?([A-Za-z][A-Za-z0-9]{0,5}(?:\.[A-Za-z]{1,3})?)\b"#)
            .map(normalizeTicker)
            .filter(isTicker)
        let bare = matches(text, pattern: #"\b([A-Z][A-Z0-9]{0,5}(?:\.[A-Z]{1,3})?)\b"#)
            .map(normalizeTicker)
            .filter(isTicker)

        var ordered: [String] = []
        for symbol in parenthetical + dollar + contextual + bare where !ordered.contains(symbol) {
            ordered.append(symbol)
        }
        guard let first = ordered.first else { return Symbols(asked: nil, companion: nil) }
        if let listing = parenthetical.first, let company = (dollar + contextual + bare).first(where: { $0 != listing }) {
            return Symbols(asked: listing, companion: company)
        }
        if let listing = parenthetical.first {
            return Symbols(asked: listing, companion: ordered.first { $0 != listing })
        }
        return Symbols(asked: first, companion: ordered.dropFirst().first)
    }

    private static func extractCost(_ text: String) -> (amount: Double, currency: String)? {
        if let hit = firstCost(in: text, pattern: #"([€$£])\s*([0-9]+(?:[.,][0-9]+)?)"#, currencyGroup: 1, amountGroup: 2) {
            return hit
        }
        return firstCost(
            in: text,
            pattern: #"([0-9]+(?:[.,][0-9]+)?)\s*(euros?|eur|dollars?|usd|pounds?|gbp)\b"#,
            currencyGroup: 2,
            amountGroup: 1
        )
    }

    private static func firstCost(in text: String, pattern: String, currencyGroup: Int, amountGroup: Int) -> (amount: Double, currency: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let amountRange = Range(match.range(at: amountGroup), in: text),
              let currencyRange = Range(match.range(at: currencyGroup), in: text),
              let amount = parseNumber(String(text[amountRange])),
              let currency = currencyCode(String(text[currencyRange]))
        else { return nil }
        return (amount, currency)
    }

    private static func extractStatedPercent(_ text: String) -> Double? {
        let folded = text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if let amount = firstNumber(in: folded, pattern: #"down\s+([0-9]+(?:[.,][0-9]+)?)\s*(?:%|percent)"#) {
            return -amount
        }
        if let amount = firstNumber(in: folded, pattern: #"up\s+([0-9]+(?:[.,][0-9]+)?)\s*(?:%|percent)"#) {
            return amount
        }
        guard let regex = try? NSRegularExpression(pattern: #"([+-])\s*([0-9]+(?:[.,][0-9]+)?)\s*%"#) else { return nil }
        let range = NSRange(folded.startIndex..., in: folded)
        guard let match = regex.firstMatch(in: folded, range: range),
              let signRange = Range(match.range(at: 1), in: folded),
              let amountRange = Range(match.range(at: 2), in: folded),
              let amount = parseNumber(String(folded[amountRange]))
        else { return nil }
        return folded[signRange] == "-" ? -amount : amount
    }

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return parseNumber(String(text[numberRange]))
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let slice = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[slice])
        }
    }

    private static func normalizeTicker(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static let stopwords: Set<String> = [
        "A", "I", "DD", "AI", "Q", "EUR", "USD", "GBP", "OK", "MY", "THE", "AND", "OR", "FOR", "TO", "OF",
        "IN", "ON", "IS", "IT", "BE", "AT", "BY", "AN", "AS", "IF", "SO", "UP", "DO", "WE", "US", "EU", "UK",
        "IMO", "FYI", "ETF", "CEO", "COO", "EPS", "PE", "YOY", "TTM", "SEC", "IPO", "GDP", "CPI", "NOT",
        "BUT", "ARE", "WAS", "HAS", "HAD", "HIS", "HER", "OUR", "YOU", "YOUR", "DOWN", "PERCENT", "EURO",
        "EUROS", "DOLLAR", "DOLLARS", "MAKE", "ABOUT", "HOLD", "SELL", "MEMO", "WRITE",
    ]

    private static func isTicker(_ symbol: String) -> Bool {
        let core = symbol.split(separator: ".").first.map(String.init) ?? symbol
        guard core.count >= 1, core.count <= 6, !stopwords.contains(core), !stopwords.contains(symbol) else { return false }
        return core.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func parseNumber(_ raw: String) -> Double? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    private static func currencyCode(_ raw: String) -> String? {
        switch raw.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) {
        case "€", "euro", "euros", "eur": "EUR"
        case "$", "dollar", "dollars", "usd": "USD"
        case "£", "pound", "pounds", "gbp": "GBP"
        default: nil
        }
    }
}
