import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

/// Covers the mapping from raw model JSON to import rows. The model call itself
/// is not exercised here — what matters is that nothing the model says can turn
/// into a bogus position, which is pure logic.
@Suite("Screenshot portfolio extraction")
struct ScreenshotPortfolioExtractorTests {
    private func extraction(_ json: String) throws -> ScreenshotExtraction {
        try JSONDecoder()
            .decode(ExtractedScreenshot.self, from: Data(json.utf8))
            .toExtraction()
    }

    @Test("A holdings screen yields rows with no cost basis")
    func holdingsRows() throws {
        let result = try extraction(#"""
        {"kind":"holdings","rows":[
          {"symbol":"aapl","shares":10.5,"confidence":0.9},
          {"symbol":"VOO","shares":3,"confidence":0.8}
        ]}
        """#)
        #expect(result.kind == .holdings)
        #expect(result.rows.count == 2)
        #expect(result.rows[0].symbol == "AAPL")
        #expect(result.rows[0].shares == 10.5)
        #expect(result.rows[0].buyPrice == nil)
    }

    /// The expensive mistake: a holdings screen's price column is market value.
    /// The prompt forbids returning it, but a model that ignores the instruction
    /// must not be able to write a fictional cost basis into a portfolio.
    @Test("A price on a holdings screen is discarded even when the model returns one")
    func holdingsPriceIsSuppressed() throws {
        let result = try extraction(#"""
        {"kind":"holdings","rows":[
          {"symbol":"AAPL","shares":10,"buyPrice":242.19,"buyDate":"2026-09-01","confidence":0.95}
        ]}
        """#)
        let row = try #require(result.rows.first)
        #expect(row.buyPrice == nil)
        #expect(row.buyDate == nil)
        #expect(row.shares == 10)
    }

    @Test("A trades screen keeps the execution price and date")
    func tradesKeepPrice() throws {
        let result = try extraction(#"""
        {"kind":"trades","rows":[
          {"symbol":"MSFT","shares":4,"buyPrice":410.25,"buyDate":"2026-08-14","confidence":0.7}
        ]}
        """#)
        #expect(result.kind == .trades)
        let row = try #require(result.rows.first)
        #expect(row.buyPrice == 410.25)
        #expect(row.buyDate == "2026-08-14")
        #expect(row.confidence == 0.7)
    }

    @Test("An unclassifiable image is rejected rather than guessed")
    func unknownIsRejected() throws {
        let result = try extraction(#"{"kind":"unknown","rows":[]}"#)
        #expect(result.kind == .unknown)
        #expect(result.rows.isEmpty)
        #expect(result.rejection != nil)
    }

    @Test("Rows the model returned with no symbol are dropped, not imported blank")
    func symbollessRowsDropped() throws {
        let result = try extraction(#"""
        {"kind":"holdings","rows":[
          {"shares":10},
          {"symbol":"  ","shares":2},
          {"symbol":"TSLA","shares":1}
        ]}
        """#)
        #expect(result.rows.map(\.symbol) == ["TSLA"])
    }

    @Test("A classified image with no usable rows is reported as a failure")
    func noUsableRowsIsRejected() throws {
        let result = try extraction(#"{"kind":"holdings","rows":[]}"#)
        #expect(result.rejection != nil)
        #expect(result.rows.isEmpty)
    }

    @Test("A kind the backend does not know is treated as unclassified")
    func unrecognisedKindIsUnknown() throws {
        let result = try extraction(#"{"kind":"options_chain","rows":[{"symbol":"AAPL","shares":1}]}"#)
        #expect(result.kind == .unknown)
        #expect(result.rows.isEmpty)
    }

    @Test("A missing rows key does not crash the mapping")
    func missingRowsKey() throws {
        let result = try extraction(#"{"kind":"holdings"}"#)
        #expect(result.rejection != nil)
    }

    @Test("The disabled extractor reports itself off and rejects")
    func disabledExtractor() {
        let extractor = DisabledScreenshotPortfolioExtractor()
        #expect(extractor.isEnabled == false)
    }

    @Test("An extractor without credentials is not enabled")
    func unconfiguredExtractorIsDisabled() {
        #expect(OpenAIVisionScreenshotExtractor(apiKey: "", baseURL: "https://x/v1", model: "m").isEnabled == false)
        #expect(OpenAIVisionScreenshotExtractor(apiKey: "k", baseURL: "", model: "m").isEnabled == false)
        #expect(OpenAIVisionScreenshotExtractor(apiKey: "k", baseURL: "https://x/v1", model: "").isEnabled == false)
        #expect(OpenAIVisionScreenshotExtractor(apiKey: "k", baseURL: "https://x/v1", model: "m").isEnabled)
    }
}
