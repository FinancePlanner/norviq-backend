@testable import StockPlanBackend
import Testing
import Vapor

@Suite("News provider selection")
struct NewsProviderSelectionTests {
    @Test("Default is finnhub; names are lowercased, trimmed, deduped; rss aliases map to jsonfeed")
    func parse() {
        #expect(NewsProviderSelection.parse(nil) == ["finnhub"])
        #expect(NewsProviderSelection.parse("") == ["finnhub"])
        #expect(NewsProviderSelection.parse(" Finnhub , jsonfeed ,finnhub") == ["finnhub", "jsonfeed"])
        #expect(NewsProviderSelection.parse("rss") == ["jsonfeed"])
        #expect(NewsProviderSelection.parse("yahoo_rss,finnhub") == ["jsonfeed", "finnhub"])
        #expect(NewsProviderSelection.parse("bogus") == [])
    }

    private struct Stub: NewsProvider {
        let name: String
        func fetch(symbols _: [String], on _: Request) async throws -> [ProviderNewsItem] {
            []
        }

        func fetchGeneral(on _: Request) async throws -> [ProviderNewsItem] {
            []
        }
    }

    @Test("Build returns nil, the single provider, or a composite in configured order, skipping unavailable ones")
    func build() {
        let finnhub = Stub(name: "finnhub")
        let jsonfeed = Stub(name: "jsonfeed")
        #expect(NewsProviderSelection.build(names: ["finnhub"], finnhub: nil, jsonfeed: nil) == nil)
        #expect(NewsProviderSelection.build(names: ["finnhub"], finnhub: finnhub, jsonfeed: jsonfeed)?.name == "finnhub")
        #expect(NewsProviderSelection.build(names: ["jsonfeed", "finnhub"], finnhub: nil, jsonfeed: jsonfeed)?.name == "jsonfeed")
        let composite = NewsProviderSelection.build(names: ["jsonfeed", "finnhub"], finnhub: finnhub, jsonfeed: jsonfeed)
        #expect(composite?.name == "composite(jsonfeed,finnhub)")
    }
}
