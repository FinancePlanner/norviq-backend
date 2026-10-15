import Foundation
import StockPlanShared

/// Turns a model draft into items we are willing to show.
///
/// The grounding check is a heuristic, not a proof: an unsourced line may
/// only contain separator-bearing numbers that match a server fact. A
/// sourced line is trusted to its source. Lines that fail are dropped, not
/// rewritten, and a language left with fewer than `minItems` lines fails the
/// whole attempt so the generator can fall back.
enum MarketBriefValidator {
    static let minItems = 3
    static let maxGreetingLength = 120

    struct Output: Equatable {
        let greeting: String?
        let items: [MarketBriefItem]
        let dropped: Int
    }

    private struct Limits {
        let maxItems: Int
        let maxLength: Int
        let kinds: Set<MarketBriefItemKind>
    }

    private static func limits(for slot: MarketBriefSlot) -> Limits {
        switch slot {
        case .morning: Limits(maxItems: 10, maxLength: 400, kinds: [.highlight, .earnings])
        case .evening: Limits(maxItems: 8, maxLength: 1000, kinds: [.story])
        }
    }

    static func validate(
        _ section: MarketBriefDraft.Section,
        slot: MarketBriefSlot,
        language: MarketBriefLanguage,
        grounded: [Double],
        allowedSources: Set<String>? = nil
    ) throws -> Output {
        let limits = limits(for: slot)
        var kept: [MarketBriefItem] = []
        var dropped = 0
        for item in section.items {
            guard kept.count < limits.maxItems else { break }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = MarketBriefItemKind(rawValue: item.kind),
                  limits.kinds.contains(kind),
                  !text.isEmpty,
                  text.count <= limits.maxLength
            else {
                dropped += 1
                continue
            }
            // Without web search the model saw no page but the headlines, so a
            // link is only a source if it is one of theirs. A made-up or
            // injected URL must not switch the number check off.
            let source = httpsURL(item.sourceUrl).flatMap { url in
                allowedSources.map { $0.contains(url) ? url : nil } ?? url
            }
            if source == nil, !isGrounded(text, grounded: grounded) {
                dropped += 1
                continue
            }
            kept.append(MarketBriefItem(kind: kind, text: text, tickers: tickers(item.tickers ?? []), sourceUrl: source))
        }
        guard kept.count >= minItems else {
            throw MarketBriefError.tooFewItems(language: language.rawValue, kept: kept.count)
        }
        let greeting = section.greeting?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(
            greeting: greeting.flatMap { $0.isEmpty || $0.count > maxGreetingLength ? nil : $0 },
            items: kept,
            dropped: dropped
        )
    }

    /// Every checked number must match some fact under one of its readings,
    /// allowing for the model's rounding (the token's tolerance) or rounding a
    /// level (±0.1%).
    static func isGrounded(_ text: String, grounded: [Double]) -> Bool {
        MarketBriefNumbers.tokens(in: text).allSatisfy { token in
            token.readings.contains { reading in
                grounded.contains { fact in abs(fact - reading) <= max(token.tolerance, abs(fact) * 0.001) }
            }
        }
    }

    static func tickers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { value in
            let ticker = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").uppercased()
            guard ticker.wholeMatch(of: #/[A-Z][A-Z.]{0,5}/#) != nil, seen.insert(ticker).inserted else { return nil }
            return ticker
        }
    }

    static func httpsURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return trimmed
    }
}
