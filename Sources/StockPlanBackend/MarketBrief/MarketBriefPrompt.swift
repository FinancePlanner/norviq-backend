import Foundation
import StockPlanShared

/// Fixed system prompt plus a facts turn, in the `AIPrompt` style. The system
/// prompt never varies, so provider-side prompt caching applies.
///
/// One call writes both languages, so en and pt-PT carry the same facts in the
/// same order and the brief costs one completion, not two.
enum MarketBriefPrompt {
    static let systemPrompt = """
    You write Norviq's market brief, a short daily note for retail investors, in two languages at once: \
    English ("en") and European Portuguese ("pt-PT", never Brazilian Portuguese).

    You receive SERVER-SELECTED FACTS as JSON: index quotes (price and changePercent, already computed), \
    recent headlines, and today's earnings calendar.

    Hard rules:
    1. Never write an index level, price, yield or percentage that is not in FACTS, unless you found it in a \
    web source and set that item's "sourceUrl" to the source's https URL.
    2. Every item that uses information from the web has "sourceUrl" set. Items built only from FACTS have \
    "sourceUrl": null.
    3. Write tickers as $TICKER in the text, and list them without "$" in "tickers".
    4. Summarise in your own words. Never copy a headline or an article sentence.
    5. No investment advice, no price targets, no "buy" or "sell".
    6. Both languages carry the same items in the same order with the same facts.
    7. pt-PT writes numbers as 25.032 and 0,77%; en writes 25,032 and 0.77%.

    Slot "morning" (15 minutes after the European open): "greeting" is a short good-morning ("Good morning," / \
    "Bom dia,"). Write 5 to 7 items of kind "highlight": the overall tone, Asia overnight, the US 10-year yield, \
    oil, notable macro data, and what investors watch today. Then 0 to 3 items of kind "earnings", one per \
    notable company reporting today, saying what to watch. Each item is at most 350 characters.

    Slot "evening" (after the US close): "greeting" is one line introducing the recap. Write 5 to 8 items of kind \
    "story": the day's most market-moving stories (companies, macro, and world events that move markets), most \
    important first. Each item is at most 900 characters.

    Reply with only this JSON object and nothing else:
    {"en":{"greeting":string|null,"items":[{"kind":"highlight"|"earnings"|"story","text":string,\
    "tickers":[string],"sourceUrl":string|null}]},"pt-PT":{same shape}}
    """

    static func messages(facts: MarketBriefFacts, webSearch: Bool) throws -> [OpenAIMessage] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let factsJSON = try String(decoding: encoder.encode(facts), as: UTF8.self)
        let research = webSearch
            ? "Use web search for today's market news and cite each source in sourceUrl."
            : "Web search is unavailable. Use only FACTS; every item has sourceUrl null."
        return [
            OpenAIMessage(role: "system", content: systemPrompt),
            OpenAIMessage(role: "user", content: "\(research)\n\nSERVER-SELECTED FACTS:\n\(factsJSON)"),
        ]
    }
}

/// The model's reply, before validation.
struct MarketBriefDraft: Decodable, Equatable {
    struct Section: Decodable, Equatable {
        let greeting: String?
        let items: [Item]
    }

    struct Item: Decodable, Equatable {
        let kind: String
        let text: String
        let tickers: [String]?
        let sourceUrl: String?
    }

    let en: Section
    let ptPT: Section

    enum CodingKeys: String, CodingKey {
        case en
        case ptPT = "pt-PT"
    }

    func section(_ language: MarketBriefLanguage) -> Section {
        language == .en ? en : ptPT
    }

    /// Models wrap JSON in fences or a sentence even under `json_object`, so
    /// take the outermost object. Plain `JSONDecoder`, not the app's
    /// `backendAPI` decoder, so the "pt-PT" key is read as written.
    static func parse(_ content: String) throws -> MarketBriefDraft {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end
        else { throw MarketBriefError.unparseableDraft }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(content[start ... end].utf8))
        } catch {
            throw MarketBriefError.unparseableDraft
        }
    }
}
