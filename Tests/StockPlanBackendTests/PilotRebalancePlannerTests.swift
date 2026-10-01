@testable import StockPlanBackend
import Testing

@Suite("PilotRebalancePlanner")
struct PilotRebalancePlannerTests {
    @Test("from cash: buys target weights")
    func fromCash() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 0.5, "MSFT": 0.5], holdings: [:], cash: 10000, prices: ["AAPL": 100, "MSFT": 250])
        #expect(plan.orders == [
            PilotOrder(symbol: "AAPL", side: .buy, quantity: 50, price: 100),
            PilotOrder(symbol: "MSFT", side: .buy, quantity: 20, price: 250),
        ])
    }

    @Test("sells come first, and a dropped symbol is sold out")
    func sellsFirst() {
        let plan = PilotRebalancePlanner.plan(weights: ["MSFT": 1.0], holdings: ["AAPL": 10], cash: 0, prices: ["AAPL": 100, "MSFT": 100])
        #expect(plan.orders == [
            PilotOrder(symbol: "AAPL", side: .sell, quantity: 10, price: 100),
            PilotOrder(symbol: "MSFT", side: .buy, quantity: 10, price: 100),
        ])
    }

    @Test("trades below max($5, 0.25% of value) are skipped")
    func threshold() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 1.0], holdings: ["AAPL": 99.99], cash: 1, prices: ["AAPL": 100])
        #expect(plan.orders.isEmpty)
    }

    @Test("an unpriced symbol is left alone and reported")
    func unpricedSymbolLeftAlone() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 0.5, "ZZZZ": 0.5], holdings: ["OLD": 5], cash: 1000, prices: ["AAPL": 100])
        #expect(plan.unpriced.sorted() == ["OLD", "ZZZZ"])
        #expect(plan.orders == [PilotOrder(symbol: "AAPL", side: .buy, quantity: 5, price: 100)])
    }

    @Test("buys never spend more than the cash available")
    func cashCap() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 1.0], holdings: [:], cash: 100, prices: ["AAPL": 30])
        let spent = plan.orders.filter { $0.side == .buy }.reduce(0.0) { $0 + $1.quantity * $1.price }
        #expect(spent <= 100 + 1e-6)
    }

    @Test("sell-to-zero passes the held quantity unrounded")
    func sellToZeroUnrounded() {
        let plan = PilotRebalancePlanner.plan(weights: ["MSFT": 1.0], holdings: ["AAPL": 1.0000006], cash: 0, prices: ["AAPL": 100, "MSFT": 100])
        #expect(plan.orders.first == PilotOrder(symbol: "AAPL", side: .sell, quantity: 1.0000006, price: 100))
    }

    @Test("a dust holding of a dropped symbol is still sold out")
    func dustSoldOut() {
        let plan = PilotRebalancePlanner.plan(weights: ["MSFT": 1.0], holdings: ["AAPL": 0.01], cash: 1000, prices: ["AAPL": 100, "MSFT": 100])
        #expect(plan.orders.contains(PilotOrder(symbol: "AAPL", side: .sell, quantity: 0.01, price: 100)))
    }
}
