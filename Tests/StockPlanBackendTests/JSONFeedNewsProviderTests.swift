import Foundation
@testable import StockPlanBackend
import Testing

@Suite("JSON Feed news provider mapping")
struct JSONFeedNewsProviderTests {
    private func fixture() throws -> JSONFeedDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jsonfeed-ticker.json")
        let data = try Data(contentsOf: url)
        return try JSONFeedDocument.decode(from: data)
    }

    @Test("Decodes JSON Feed 1.1 with the _feeds extension and fractional dates")
    func decodesDocument() throws {
        let doc = try fixture()
        #expect(doc.title == "Merged timeline")
        #expect(doc.items.count == 4)
        #expect(doc.items[0].feeds.sourceName == "CNBC")
        #expect(doc.items[0].feeds.sourceUrl == "https://www.cnbc.com")
        #expect(doc.items[0].image == "https://pub.example/a.jpg")
        #expect(doc.items[3].datePublished.timeIntervalSince1970 == 1_789_633_800.5)
        #expect(doc.feeds?.warming.count == 1)
    }

    @Test("General items are tagged GENERAL and carry source and image, never a summary")
    func mapsGeneral() throws {
        let doc = try fixture()
        let items = JSONFeedMapping.providerItems(from: doc, symbolByFeedURL: [:], defaultSymbol: "GENERAL", maxPerSymbol: nil)
        #expect(items.count == 4)
        #expect(items[0].symbol == "GENERAL")
        #expect(items[0].headline == "Fed holds rates")
        #expect(items[0].source == "CNBC")
        #expect(items[0].url == "https://pub.example/story")
        #expect(items[0].image == "https://pub.example/a.jpg")
        #expect(items[0].summary == nil)
        #expect(items[0].publishedAt == Date(timeIntervalSince1970: 1_789_642_800))
    }

    @Test("Symbol items are tagged by the feed URL that produced them and capped per symbol")
    func mapsSymbolsByFeedURL() throws {
        let doc = try fixture()
        let bySymbol = [
            "https://feeds.finance.yahoo.com/rss/2.0/headline?s=AAPL&region=US&lang=en-US": "AAPL",
            "https://feeds.finance.yahoo.com/rss/2.0/headline?s=MSFT&region=US&lang=en-US": "MSFT",
        ]
        let items = JSONFeedMapping.providerItems(from: doc, symbolByFeedURL: bySymbol, defaultSymbol: nil, maxPerSymbol: 1)
        // CNBC item has no symbol mapping and no default → dropped. AAPL capped to 1. MSFT 1.
        #expect(items.map(\.symbol) == ["AAPL", "MSFT"])
        #expect(items[0].headline == "Apple beats")
    }

    @Test("Symbol feed template expands and rejects symbols that would break the URL")
    func symbolFeedURLs() {
        let template = "https://feeds.finance.yahoo.com/rss/2.0/headline?s={symbol}&region=US"
        #expect(JSONFeedNewsProvider.feedURL(template: template, symbol: "aapl") == "https://feeds.finance.yahoo.com/rss/2.0/headline?s=AAPL&region=US")
        #expect(JSONFeedNewsProvider.feedURL(template: template, symbol: "BRK.B") == "https://feeds.finance.yahoo.com/rss/2.0/headline?s=BRK.B&region=US")
        #expect(JSONFeedNewsProvider.feedURL(template: template, symbol: "a b/c") == nil)
        #expect(JSONFeedNewsProvider.feedURL(template: "", symbol: "AAPL") == nil)
    }

    @Test("Curated feed list env is split, trimmed and deduped")
    func curatedList() {
        #expect(JSONFeedNewsProvider.feedList(" https://a/rss , https://b/rss,https://a/rss,, ") == ["https://a/rss", "https://b/rss"])
        #expect(JSONFeedNewsProvider.feedList(nil) == [])
    }
}
