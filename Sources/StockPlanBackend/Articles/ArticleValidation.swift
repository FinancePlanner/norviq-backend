import Foundation
import Vapor

/// Input rules for articles. Pure, so they test without a database.
enum ArticleValidation {
    static let maxPerDay = 3
    static let titleRange = 8 ... 140
    static let bodyRange = 300 ... 20000
    static let maxBullets = 3
    static let bulletRange = 10 ... 240
    static let maxTickers = 5
    static let disclosureRange = 10 ... 500
    static let maxSlugLength = 80
    /// No i, l, o, 0 or 1: a code is read off an image card and typed back in.
    static let codeAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    static func title(_ raw: String) throws -> String {
        let title = collapse(raw)
        guard titleRange.contains(title.count) else {
            throw Abort(.badRequest, reason: "Title must be 8–140 characters.")
        }
        return title
    }

    static func body(_ raw: String) throws -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bodyRange.contains(body.count) else {
            throw Abort(.badRequest, reason: "The article must be 300–20,000 characters.")
        }
        return body
    }

    static func bulletPoints(_ raw: [String]) throws -> [String] {
        let items = raw.map(collapse).filter { !$0.isEmpty }
        guard (1 ... maxBullets).contains(items.count) else {
            throw Abort(.badRequest, reason: "Add one to three key points.")
        }
        guard items.allSatisfy({ bulletRange.contains($0.count) }) else {
            throw Abort(.badRequest, reason: "Each key point must be 10–240 characters.")
        }
        return items
    }

    static func tickers(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        var tickers: [String] = []
        for item in raw {
            var ticker = item.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if ticker.hasPrefix("$") {
                ticker.removeFirst()
            }
            if ticker.isEmpty {
                continue
            }
            guard isTicker(ticker) else {
                throw Abort(.badRequest, reason: "\"\(ticker.prefix(12))\" isn't a ticker symbol.")
            }
            if seen.insert(ticker).inserted {
                tickers.append(ticker)
            }
        }
        guard (1 ... maxTickers).contains(tickers.count) else {
            throw Abort(.badRequest, reason: "Tag one to five tickers.")
        }
        return tickers
    }

    static func disclosure(_ raw: String) throws -> String {
        let disclosure = collapse(raw)
        guard disclosureRange.contains(disclosure.count) else {
            throw Abort(.badRequest, reason: "Add a disclosure of 10–500 characters, e.g. \"No position\".")
        }
        return disclosure
    }

    static func slug(from title: String) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength))
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "article" : slug
    }

    static func wordCount(markdown: String) -> Int {
        let stripped = markdown.replacingOccurrences(of: #"\]\([^)]*\)"#, with: " ", options: .regularExpression)
        return stripped
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#*_>`[]()!~|-")))
            .filter { word in word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            .count
    }

    static func makeCode() -> String {
        String((0 ..< 8).map { _ in codeAlphabet.randomElement()! })
    }

    private static func isTicker(_ value: String) -> Bool {
        guard (1 ... 10).contains(value.count), let first = value.first, first.isASCII, first.isLetter else {
            return false
        }
        return value.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
