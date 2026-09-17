import Foundation
import Vapor

/// News from any JSON Feed 1.1 source — in practice the cluster's shared feed
/// aggregator, which turns RSS/Atom/JSON Feed publishers into this shape.
/// Named for the wire format, not the service, so swapping the upstream is
/// configuration rather than code.
struct JSONFeedNewsProvider: NewsProvider {
    let name = "jsonfeed"
    let client: any FeedsClient
    /// Curated market-wide feeds for `fetchGeneral`.
    let generalFeeds: [String]
    /// Template with `{symbol}` for per-symbol feeds; empty disables `fetch(symbols:)`.
    let symbolFeedTemplate: String
    let maxArticlesPerSymbol: Int?
    let generalLimit: Int

    init(
        client: any FeedsClient,
        generalFeeds: [String],
        symbolFeedTemplate: String = Environment.get("NEWS_SYMBOL_FEED_TEMPLATE") ?? "",
        maxArticlesPerSymbol: Int? = Environment.get("NEWS_RSS_MAX_ARTICLES_PER_SYMBOL").flatMap(Int.init) ?? 15,
        generalLimit: Int = 60
    ) {
        self.client = client
        self.generalFeeds = generalFeeds
        self.symbolFeedTemplate = symbolFeedTemplate
        self.maxArticlesPerSymbol = maxArticlesPerSymbol
        self.generalLimit = generalLimit
    }

    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
        guard !symbolFeedTemplate.isEmpty else {
            return []
        }
        var symbolByFeedURL: [String: String] = [:]
        for symbol in Set(symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }).sorted() {
            if let url = Self.feedURL(template: symbolFeedTemplate, symbol: symbol) {
                symbolByFeedURL[url] = symbol
            }
        }
        guard !symbolByFeedURL.isEmpty else {
            return []
        }
        var items: [ProviderNewsItem] = []
        let urls = symbolByFeedURL.keys.sorted()
        for chunk in stride(from: 0, to: urls.count, by: HTTPFeedsClient.maxFeedsPerCall) {
            let batch = Array(urls[chunk ..< min(chunk + HTTPFeedsClient.maxFeedsPerCall, urls.count)])
            let limit = min(200, batch.count * (maxArticlesPerSymbol ?? 25))
            let doc = try await client.items(feeds: batch, limit: limit, on: req)
            items.append(contentsOf: JSONFeedMapping.providerItems(
                from: doc, symbolByFeedURL: symbolByFeedURL, defaultSymbol: nil, maxPerSymbol: maxArticlesPerSymbol
            ))
        }
        return items
    }

    func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
        guard !generalFeeds.isEmpty else {
            return []
        }
        let doc = try await client.items(feeds: generalFeeds, limit: generalLimit, on: req)
        return JSONFeedMapping.providerItems(from: doc, symbolByFeedURL: [:], defaultSymbol: "GENERAL", maxPerSymbol: nil)
    }

    /// Expands `{symbol}` in a template. Symbols with characters that are not
    /// safe inside a query value are rejected rather than escaped, because a
    /// mangled ticker returns someone else's news.
    static func feedURL(template: String, symbol: String) -> String? {
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !template.isEmpty, !symbol.isEmpty, template.contains("{symbol}") else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-="))
        guard symbol.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return template.replacingOccurrences(of: "{symbol}", with: symbol)
    }

    /// Splits a comma-separated env value into a trimmed, deduped, ordered list.
    static func feedList(_ raw: String?) -> [String] {
        var seen = Set<String>()
        return (raw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum JSONFeedMapping {
    /// Maps aggregator items to provider items. An item's symbol is looked up by
    /// the feed that produced it; items from unmapped feeds get `defaultSymbol`
    /// or are dropped when that is nil. `maxPerSymbol` caps each symbol.
    static func providerItems(
        from doc: JSONFeedDocument,
        symbolByFeedURL: [String: String],
        defaultSymbol: String?,
        maxPerSymbol: Int?
    ) -> [ProviderNewsItem] {
        var counts: [String: Int] = [:]
        var out: [ProviderNewsItem] = []
        for item in doc.items {
            guard let symbol = symbolByFeedURL[item.feeds.feedUrl] ?? defaultSymbol else {
                continue
            }
            if let maxPerSymbol, maxPerSymbol > 0, counts[symbol, default: 0] >= maxPerSymbol {
                continue
            }
            counts[symbol, default: 0] += 1
            out.append(ProviderNewsItem(
                symbol: symbol,
                headline: item.title,
                source: item.feeds.sourceName,
                url: item.url,
                summary: nil,
                image: item.image,
                publishedAt: item.datePublished
            ))
        }
        return out
    }
}
