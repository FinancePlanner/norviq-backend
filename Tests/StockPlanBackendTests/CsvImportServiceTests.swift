import Foundation
@testable import StockPlanBackend
import Testing

@Suite("CsvImportService Unit Tests")
struct CsvImportServiceTests {
    let service = CsvImportService()

    @Test("Infer delimiter from header line")
    func inferDelimiter() {
        // Since inferDelimiter is private, we can't test it directly unless we make it @testable
        // or test it via the public preview() method. We'll use preview().
    }

    @Test("Preview supports comma delimiter")
    func previewComma() throws {
        let csv = """
        symbol,shares,buy_price,buy_date
        AAPL,10,150.5,2026-01-01
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.items[0].symbol == "AAPL")
        #expect(response.items[0].shares == 10)
        #expect(response.items[0].buyPrice == 150.5)
    }

    @Test("Preview supports semicolon delimiter")
    func previewSemicolon() throws {
        let csv = """
        symbol;shares;buy_price;buy_date
        MSFT;5;250.75;2026-02-01
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.items[0].symbol == "MSFT")
        #expect(response.items[0].shares == 5)
    }

    @Test("Preview supports header aliases")
    func headerAliases() throws {
        let csv = """
        Ticker,Qty,Cost Basis,Opened
        TSLA,2,700,2026-03-01
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.items[0].symbol == "TSLA")
        #expect(response.items[0].shares == 2)
        #expect(response.items[0].buyPrice == 700)
        #expect(response.items[0].buyDate == "2026-03-01")
    }

    @Test("Preview handles quoted fields with delimiters inside")
    func quotedFields() throws {
        let csv = """
        symbol,shares,notes
        AAPL,10,"Bought in Cupertino, CA"
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.items[0].notes == "Bought in Cupertino, CA")
    }

    @Test("Date normalization supports multiple formats")
    func dateNormalization() {
        #expect(CsvImportService.normalizeDateOnlyString("2026-01-01") == "2026-01-01")
        #expect(CsvImportService.normalizeDateOnlyString("01/02/2026") == "2026-01-02")
        #expect(CsvImportService.normalizeDateOnlyString("2026/03/04") == "2026-03-04")
        #expect(CsvImportService.normalizeDateOnlyString("20260506") == "2026-05-06")
        #expect(CsvImportService.normalizeDateOnlyString("2026-01-01T12:00:00Z") == "2026-01-01")
    }

    @Test("Preview allows empty optional numeric and date fields")
    func emptyOptionalFields() throws {
        let csv = """
        symbol,shares,buy_price,buy_date,notes
        NVDA,2,,,
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.items[0].symbol == "NVDA")
        #expect(response.items[0].shares == 2)
        #expect(response.items[0].buyPrice == nil)
        #expect(response.items[0].buyDate == nil)
        #expect(response.errors.isEmpty)
    }

    @Test("Preview reports errors for missing symbols")
    func missingSymbol() throws {
        let csv = """
        symbol,shares
        AAPL,10
        ,5
        """
        let response = try service.preview(csv: csv, provider: "test")
        #expect(response.items.count == 1)
        #expect(response.errors.count == 1)
        #expect(response.errors[0].line == 3)
        #expect(response.errors[0].message == "Missing symbol.")
    }

    @Test("Preview throws error for empty body")
    func testEmptyBody() {
        #expect(throws: CsvImportServiceError.emptyBody) {
            try service.preview(csv: "", provider: "test")
        }
        #expect(throws: CsvImportServiceError.emptyBody) {
            try service.preview(csv: "   \n\n  ", provider: "test")
        }
    }

    @Test("Preview throws error for missing symbol column")
    func testMissingSymbolColumn() {
        let csv = "shares,price\n10,100"
        #expect(throws: CsvImportServiceError.missingSymbolColumn) {
            try service.preview(csv: csv, provider: "test")
        }
    }
}
