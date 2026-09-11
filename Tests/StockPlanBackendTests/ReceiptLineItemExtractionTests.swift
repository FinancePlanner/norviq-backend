import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

/// Covers the mapping from raw model JSON to a receipt draft. The model call is
/// not exercised; what matters is that nothing it returns can become a bogus
/// expense line.
@Suite("Receipt line item extraction")
struct ReceiptLineItemExtractionTests {
    private func draft(_ json: String) throws -> ReceiptDraft {
        try JSONDecoder()
            .decode(ExtractedReceipt.self, from: Data(json.utf8))
            .toDraft()
    }

    @Test("Line items are extracted and carry through to the draft")
    func extractsLineItems() throws {
        let result = try draft(#"""
        {"merchant":"Pingo Doce","total":5.50,"currency":"eur","date":"2026-09-01",
         "lineItems":[
           {"description":"Pão","amount":2.10},
           {"description":"Leite","amount":3.40,"quantity":2}
         ]}
        """#)
        #expect(result.lineItems.count == 2)
        #expect(result.lineItems[0].description == "Pão")
        #expect(result.lineItems[1].quantity == 2)
        #expect(result.currency == "EUR")
        #expect(result.source == .ocr)
    }

    @Test("Items that reconcile with the total are flagged as reconciling")
    func reconciles() throws {
        let result = try draft(#"""
        {"total":5.50,"lineItems":[{"description":"Pão","amount":2.10},{"description":"Leite","amount":3.40}]}
        """#)
        #expect(result.lineItemsReconcile == true)
    }

    /// A misread figure must be visible, not silently trusted — the review UI
    /// shows both numbers when this is false.
    @Test("A total that disagrees with the items does not reconcile")
    func doesNotReconcile() throws {
        let result = try draft(#"""
        {"total":9.90,"lineItems":[{"description":"Pão","amount":2.10}]}
        """#)
        #expect(result.lineItemsReconcile == false)
    }

    @Test("A line with no amount is dropped rather than imported as zero")
    func dropsAmountlessLines() throws {
        let result = try draft(#"""
        {"total":2.10,"lineItems":[
          {"description":"Pão","amount":2.10},
          {"description":"Saco"},
          {"amount":1.00}
        ]}
        """#)
        #expect(result.lineItems.map(\.description) == ["Pão"])
    }

    @Test("A blank description is not a usable line")
    func dropsBlankDescriptions() throws {
        let result = try draft(#"{"lineItems":[{"description":"   ","amount":1.0}]}"#)
        #expect(result.lineItems.isEmpty)
    }

    @Test("A receipt with no line items still produces a usable header draft")
    func headerOnly() throws {
        let result = try draft(#"{"merchant":"Continente","total":12.30}"#)
        #expect(result.lineItems.isEmpty)
        #expect(result.lineItemsReconcile == nil)
        #expect(result.merchant == "Continente")
    }

    @Test("A response with only line items still counts as content")
    func lineItemsAloneAreContent() throws {
        let extracted = try JSONDecoder().decode(
            ExtractedReceipt.self,
            from: Data(#"{"lineItems":[{"description":"Pão","amount":2.10}]}"#.utf8)
        )
        #expect(extracted.hasContent)
    }

    @Test("A completely empty extraction is not content")
    func emptyIsNotContent() throws {
        let extracted = try JSONDecoder().decode(ExtractedReceipt.self, from: Data("{}".utf8))
        #expect(extracted.hasContent == false)
    }
}
