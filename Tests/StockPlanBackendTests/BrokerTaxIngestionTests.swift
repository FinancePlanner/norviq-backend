@testable import StockPlanBackend
import Testing

@Suite("Broker tax ingestion")
struct BrokerTaxIngestionTests {
    private let reconciler = IBKROpeningLotReconciler()

    @Test
    func `infers only the quantity not explained by stored trades`() {
        #expect(reconciler.requiredQuantity(position: 50, bought: 30, sold: 10) == 30)
        #expect(reconciler.requiredQuantity(position: 20, bought: 30, sold: 10) == 0)
    }

    @Test
    func `preserves quantity already consumed from an inferred lot`() throws {
        #expect(try reconciler.remainingQuantity(required: 12, consumed: 5) == 7)
    }

    @Test
    func `requires rebuild when corrected history is below consumed quantity`() {
        #expect(throws: IBKROpeningLotReconciliationError.self) {
            try reconciler.remainingQuantity(required: 4, consumed: 5)
        }
    }

    @Test
    func `allocates acquisition fees into per-unit basis`() {
        let calculator = TaxAcquisitionBasisCalculator()
        #expect(calculator.unitBasis(quantity: 10, price: 100, fees: 5) == 100.5)
        #expect(calculator.unitBasis(quantity: 10, price: 100, fees: -5) == 100.5)
    }
}
