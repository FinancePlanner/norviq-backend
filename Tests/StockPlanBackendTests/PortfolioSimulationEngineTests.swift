@testable import StockPlanBackend
import StockPlanShared
import Testing

struct PortfolioSimulationEngineTests {
    private let engine = RebalancingEngine()
    private let builder = SimulationAllocationModelBuilder()

    // MARK: - Model construction

    @Test
    func `weights below ten thousand basis points leave the remainder in a cash bucket`() throws {
        let model = try builder.makeModel(for: fixture(legs: [("AAPL", 3000), ("MSFT", 2000)]))

        #expect(model.buckets.count == 3)
        #expect(model.buckets.last?.id == SimulationAllocationModelBuilder.cashLeafIdentifier)
        #expect(model.buckets.last?.targetBasisPoints == 5000)
        #expect(model.buckets.last?.leaves.first?.kind == .cash)
        #expect(model.buckets.last?.leaves.first?.symbol == nil)
        #expect(model.buckets.reduce(0) { $0 + $1.targetBasisPoints } == 10000)
    }

    @Test
    func `weights totalling exactly ten thousand basis points omit the cash bucket`() throws {
        // A zero-basis-point cash bucket would fail the engine's `targetBasisPoints > 0`
        // check, so the builder must drop it entirely rather than emit an empty one.
        let model = try builder.makeModel(for: fixture(legs: [("AAPL", 6000), ("MSFT", 4000)]))

        #expect(model.buckets.count == 2)
        #expect(model.buckets.allSatisfy { $0.leaves.allSatisfy { $0.kind == .security } })
        try engine.validate(model)
    }

    @Test
    func `legs totalling more than ten thousand basis points are rejected`() throws {
        #expect(throws: SimulationModelError.weightsExceedTotal(11000)) {
            try builder.makeModel(for: fixture(legs: [("AAPL", 6000), ("MSFT", 5000)]))
        }
    }

    @Test
    func `a synthetic model passes the engine's own validation`() throws {
        let model = try builder.makeModel(for: fixture(legs: [("AAPL", 4000), ("MSFT", 3500)]))
        try engine.validate(model)
    }

    @Test
    func `disabling fractional shares maps to a whole share quantity increment`() throws {
        // The engine never reads `fractionalSharesEnabled`; only `quantityIncrement`
        // reaches the rounding. Without this mapping the toggle is a silent no-op.
        let whole = try builder.makeModel(for: fixture(legs: [("AAPL", 10000)], fractional: false))
        let fractional = try builder.makeModel(for: fixture(legs: [("AAPL", 10000)], fractional: true))

        #expect(whole.quantityIncrement == 1)
        #expect(fractional.quantityIncrement == 0.001)
    }

    // MARK: - Simulation

    @Test
    func `a from scratch simulation with zero quantity price carriers produces only buys`() throws {
        let simulation = fixture(legs: [("AAPL", 4000), ("MSFT", 3500), ("NVDA", 2500)], fractional: true)
        let model = try builder.makeModel(for: simulation)
        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 10000),
            snapshot: emptySnapshot(priced: ["AAPL": 100, "MSFT": 50, "NVDA": 25])
        )

        #expect(result.trades.count == 3)
        #expect(result.trades.allSatisfy { $0.side == .buy })
        #expect(result.totalValueBefore == 10000)
        #expect(result.trades.first { $0.symbol == "AAPL" }?.notional == 4000)
        #expect(result.trades.first { $0.symbol == "MSFT" }?.notional == 3500)
        #expect(result.trades.first { $0.symbol == "NVDA" }?.notional == 2500)
        #expect(result.driftAfterBasisPoints == 0)
        // Buys carry no realized gain: there is nothing to realize.
        #expect(result.trades.allSatisfy { $0.estimatedRealizedGainLoss == nil })
    }

    @Test
    func `whole share mode floors quantities and leaves residual cash`() throws {
        let simulation = fixture(legs: [("AAPL", 10000)], fractional: false)
        let model = try builder.makeModel(for: simulation)
        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 1000),
            snapshot: emptySnapshot(priced: ["AAPL": 231.40])
        )

        let trade = try #require(result.trades.first)
        #expect(trade.quantity == 4)
        #expect(trade.notional == 925.60)
        // Whole-share rounding means a fully-invested target can never reach zero drift.
        #expect(result.driftAfterBasisPoints > 0)
    }

    @Test
    func `a cloned simulation sells overweight holdings and buys underweight legs`() throws {
        let simulation = fixture(
            legs: [("AAPL", 5000), ("MSFT", 5000)],
            mode: .cloneCurrentPortfolio,
            fractional: true
        )
        let model = try builder.makeModel(for: simulation)
        let snapshot = RebalancingValuationSnapshot(
            holdings: [
                .init(symbol: "AAPL", name: "AAPL", quantity: 80, price: 100, averageCost: 60),
                .init(symbol: "MSFT", name: "MSFT", quantity: 20, price: 100, averageCost: 90),
            ],
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: nil,
            warnings: []
        )

        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 0),
            snapshot: snapshot
        )

        #expect(result.trades.first { $0.symbol == "AAPL" }?.side == .sell)
        #expect(result.trades.first { $0.symbol == "MSFT" }?.side == .buy)
        #expect(result.trades.first { $0.symbol == "AAPL" }?.estimatedRealizedGainLoss != nil)
        #expect(result.trades.first { $0.symbol == "MSFT" }?.estimatedRealizedGainLoss == nil)
        #expect(result.driftAfterBasisPoints == 0)
    }

    @Test
    func `a cloned simulation fully sells a holding that is not a target leg`() throws {
        let simulation = fixture(legs: [("AAPL", 10000)], mode: .cloneCurrentPortfolio, fractional: true)
        let model = try builder.makeModel(for: simulation)
        let snapshot = RebalancingValuationSnapshot(
            holdings: [
                .init(symbol: "AAPL", name: "AAPL", quantity: 50, price: 100, averageCost: 100),
                .init(symbol: "TSLA", name: "TSLA", quantity: 10, price: 100, averageCost: 100),
            ],
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: nil,
            warnings: []
        )

        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 0),
            snapshot: snapshot
        )

        #expect(result.trades.first { $0.symbol == "TSLA" }?.side == .sell)
        #expect(result.trades.first { $0.symbol == "TSLA" }?.notional == 1000)
    }

    @Test
    func `a leg with no available price fails rather than silently dropping the position`() throws {
        let simulation = fixture(legs: [("AAPL", 5000), ("DELISTED", 5000)], fractional: true)
        let model = try builder.makeModel(for: simulation)

        #expect(throws: (any Error).self) {
            try engine.simulate(
                portfolioId: simulation.id,
                model: model,
                request: builder.makeRequest(for: model, cashFlow: 10000),
                snapshot: emptySnapshot(priced: ["AAPL": 100])
            )
        }
    }

    @Test
    func `capital below the minimum trade amount produces no trades`() throws {
        let simulation = fixture(legs: [("AAPL", 10000)], fractional: true, minimumTrade: 500)
        let model = try builder.makeModel(for: simulation)
        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 100),
            snapshot: emptySnapshot(priced: ["AAPL": 100])
        )

        #expect(result.trades.isEmpty)
    }

    @Test
    func `fees reduce the capital available to deploy`() throws {
        let simulation = fixture(legs: [("AAPL", 10000)], fractional: true, flatFee: 1, variableFeeBps: 25)
        let model = try builder.makeModel(for: simulation)
        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 1000),
            snapshot: emptySnapshot(priced: ["AAPL": 100])
        )

        #expect(result.estimatedFees > 0)
        let trade = try #require(result.trades.first)
        // Buying the full 1000 plus fees would overdraw the cash, so the engine
        // must scale the buy down to what the capital actually covers.
        #expect(trade.notional + result.estimatedFees <= 1000.01)
    }

    @Test
    func `one hundred legs simulate without error`() throws {
        let legs = (0 ..< 100).map { ("SYM\($0)", 100) }
        let simulation = fixture(legs: legs, fractional: true)
        let model = try builder.makeModel(for: simulation)
        let prices = Dictionary(uniqueKeysWithValues: legs.map { ($0.0, 10.0) })

        let result = try engine.simulate(
            portfolioId: simulation.id,
            model: model,
            request: builder.makeRequest(for: model, cashFlow: 100_000),
            snapshot: emptySnapshot(priced: prices)
        )

        #expect(result.trades.count == 100)
        #expect(result.driftAfterBasisPoints == 0)
    }

    // MARK: - Fixtures

    private func fixture(
        legs: [(String, Int)],
        mode: PortfolioSimulationMode = .fromScratch,
        fractional: Bool = false,
        minimumTrade: Double = 1,
        flatFee: Double = 0,
        variableFeeBps: Int = 0
    ) -> PortfolioSimulation {
        PortfolioSimulation(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Simulation",
            mode: mode,
            sourcePortfolioId: mode == .cloneCurrentPortfolio ? "portfolio" : nil,
            baseCurrency: "USD",
            targetCapital: 10000,
            fractionalSharesEnabled: fractional,
            quantityIncrement: 0.001,
            minimumTradeAmount: minimumTrade,
            flatFee: flatFee,
            variableFeeBasisPoints: variableFeeBps,
            revision: 1,
            legs: legs.enumerated().map { offset, leg in
                PortfolioSimulationLeg(symbol: leg.0, targetBasisPoints: leg.1, sortOrder: offset)
            },
            createdAt: "2026-09-12T12:00:00Z"
        )
    }

    /// A from-scratch simulation owns nothing, so every target symbol enters the
    /// snapshot as a zero-quantity holding that exists only to carry a live price.
    private func emptySnapshot(priced: [String: Double]) -> RebalancingValuationSnapshot {
        RebalancingValuationSnapshot(
            holdings: priced.keys.sorted().map { symbol in
                .init(symbol: symbol, name: symbol, quantity: 0, price: priced[symbol] ?? 0, averageCost: 0)
            },
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: "2026-09-12T12:00:00Z",
            warnings: []
        )
    }
}
