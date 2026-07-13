import Foundation
import StockPlanShared

enum FinancingOfferExtractor {
    static func extract(text: String, sourceDomain: String?) -> FinancingImportResponse {
        let normalized = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        let term = firstInt(patterns: [#"(?i)(?:term|prazo|durée|laufzeit|plazo|durata)[^0-9]{0,20}([0-9]{1,3})\s*(?:months|meses|mois|monate|mesi|mies)"#, #"([0-9]{1,3})\s*(?:monthly payments|mensalidades|mensualités|monatsraten|cuotas|rate)"#], text: normalized)
        let effective = firstDouble(patterns: [#"(?i)(?:TAEG|TAE|APR|RRSO|CET|effective annual rate|effektiver jahreszins)[^0-9]{0,20}([0-9]+(?:[.,][0-9]+)?)\s*%"#], text: normalized)
        let monthly = firstDouble(patterns: [#"(?i)(?:monthly payment|mensalidade|mensualité|monatsrate|cuota mensual|rata mensile|parcela)[^0-9]{0,30}([0-9][0-9., ]*)"#], text: normalized)
        let price = firstDouble(patterns: [#"(?i)(?:cash price|purchase price|preço|prix|kaufpreis|precio|prezzo|cena)[^0-9]{0,30}([0-9][0-9., ]*)"#], text: normalized)
        let currency: String? = normalized.contains("R$") ? "BRL" : normalized.contains("$") ? "USD" : normalized.contains("zł") ? "PLN" : normalized.contains("€") ? "EUR" : nil
        let fields = [term != nil, effective != nil, monthly != nil, price != nil].filter(\.self).count
        guard fields > 0 else {
            return .init(recognized: false, draft: nil, sourceDomain: sourceDomain, warnings: ["No financing terms were recognized. Enter the offer manually."])
        }
        let draft = FinancingOfferDraft(purchaseAmount: price, termMonths: term, monthlyPayment: monthly, effectiveAnnualRate: effective, currency: currency, confidence: Double(fields) / 4)
        return .init(recognized: true, draft: draft, sourceDomain: sourceDomain, warnings: ["Imported values are unverified. Confirm every field against the provider's disclosure before saving."])
    }

    private static func firstInt(patterns: [String], text: String) -> Int? {
        firstCapture(patterns: patterns, text: text).flatMap { Int($0.replacingOccurrences(of: " ", with: "")) }
    }

    private static func firstDouble(patterns: [String], text: String) -> Double? {
        firstCapture(patterns: patterns, text: text).flatMap(parseNumber)
    }

    private static func firstCapture(patterns: [String], text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text)
            else { continue }
            return String(text[capture])
        }
        return nil
    }

    private static func parseNumber(_ raw: String) -> Double? {
        var value = raw.replacingOccurrences(of: " ", with: "")
        if value.contains(","), value.contains(".") {
            if value.lastIndex(of: ",")! > value.lastIndex(of: ".")! {
                value = value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                value = value.replacingOccurrences(of: ",", with: "")
            }
        } else if value.contains(",") {
            let suffix = value.split(separator: ",").last?.count ?? 0
            value = suffix <= 2 ? value.replacingOccurrences(of: ",", with: ".") : value.replacingOccurrences(of: ",", with: "")
        }
        return Double(value)
    }
}
