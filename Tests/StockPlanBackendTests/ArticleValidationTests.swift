import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Article validation")
struct ArticleValidationTests {
    @Test("titles collapse whitespace and must be 8–140 characters")
    func titles() throws {
        #expect(try ArticleValidation.title("  Why   2027 could reprice ") == "Why 2027 could reprice")
        #expect(throws: (any Error).self) { try ArticleValidation.title("short") }
        #expect(throws: (any Error).self) { try ArticleValidation.title(String(repeating: "a", count: 141)) }
    }

    @Test("body must be 300–20,000 characters after trimming")
    func bodies() throws {
        let ok = String(repeating: "a", count: 300)
        #expect(try ArticleValidation.body("\n\(ok)\n") == ok)
        #expect(throws: (any Error).self) { try ArticleValidation.body(String(repeating: "a", count: 299)) }
        #expect(throws: (any Error).self) { try ArticleValidation.body(String(repeating: "a", count: 20001)) }
    }

    @Test("1–3 key points, blanks dropped, each 10–240 characters")
    func bullets() throws {
        #expect(try ArticleValidation.bulletPoints(["  First key point  ", "", " "]) == ["First key point"])
        #expect(throws: (any Error).self) { try ArticleValidation.bulletPoints([]) }
        #expect(throws: (any Error).self) { try ArticleValidation.bulletPoints(["too short"]) }
        #expect(throws: (any Error).self) {
            try ArticleValidation.bulletPoints(["Point number one", "Point number two", "Point number three", "Point number four"])
        }
    }

    @Test("tickers drop $, uppercase, dedupe, keep order, cap at five and reject bad shapes")
    func tickers() throws {
        #expect(try ArticleValidation.tickers(["$next", "NEXT", " brk.b ", "rds-a"]) == ["NEXT", "BRK.B", "RDS-A"])
        #expect(throws: (any Error).self) { try ArticleValidation.tickers([]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["A", "B", "C", "D", "E", "F"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["1ABC"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["TOOLONGTICK"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["NV DA"]) }
    }

    @Test("disclosure is required, 10–500 characters")
    func disclosure() throws {
        #expect(try ArticleValidation.disclosure(" No position in $NEXT ") == "No position in $NEXT")
        #expect(throws: (any Error).self) { try ArticleValidation.disclosure("none") }
        #expect(throws: (any Error).self) { try ArticleValidation.disclosure(String(repeating: "a", count: 501)) }
    }

    @Test("slugs are ascii, dashed, at most 80 characters and never empty")
    func slugs() {
        #expect(ArticleValidation.slug(from: "Before the Next Phase: Why 2027 Could Reprice NextDecade") == "before-the-next-phase-why-2027-could-reprice-nextdecade")
        #expect(ArticleValidation.slug(from: "Ação $NVDA — 100%!") == "a-o-nvda-100")
        #expect(ArticleValidation.slug(from: "!!!") == "article")
        let long = ArticleValidation.slug(from: String(repeating: "word ", count: 40))
        #expect(long.count <= 80 && !long.hasSuffix("-"))
    }

    @Test("word count ignores markdown punctuation")
    func words() {
        #expect(ArticleValidation.wordCount(markdown: "# Title\n\n**Bold** text, [a link](https://x.com) - item") == 6)
    }

    @Test("codes are 8 chars from the unambiguous alphabet")
    func codes() {
        let code = ArticleValidation.makeCode()
        #expect(code.count == 8)
        #expect(code.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
    }
}
