@testable import StockPlanBackend
import StockPlanShared
import Testing

struct RebalancingEngineTests {
    private let engine = RebalancingEngine()

    @Test
    func `sixty forty portfolio at sixty eight thirty two produces exact balancing trades`() throws {
        let model = fixtureModel()
        let snapshot = RebalancingValuationSnapshot(
            holdings: [
                .init(symbol: "STOCK", name: "Stocks", quantity: 68, price: 1, averageCost: 0.8),
                .init(symbol: "BOND", name: "Bonds", quantity: 32, price: 1, averageCost: 0.9),
            ],
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: "2026-07-14T12:00:00Z",
            warnings: []
        )

        let overview = try engine.overview(portfolioId: "portfolio", model: model, snapshot: snapshot)
        let simulation = try engine.simulate(
            portfolioId: "portfolio",
            model: model,
            request: .init(modelId: model.id, modelRevision: model.revision),
            snapshot: snapshot
        )

        #expect(overview.totalDriftBasisPoints == 800)
        #expect(simulation.driftBeforeBasisPoints == 800)
        #expect(simulation.driftAfterBasisPoints == 0)
        #expect(simulation.trades.count == 2)
        #expect(simulation.trades.first { $0.symbol == "STOCK" }?.side == .sell)
        #expect(simulation.trades.first { $0.symbol == "STOCK" }?.notional == 8)
        #expect(simulation.trades.first { $0.symbol == "BOND" }?.side == .buy)
        #expect(simulation.estimatedRealizedGainLoss == 1.6)
    }

    @Test
    func `unassigned holding contributes to total variation drift`() throws {
        let model = fixtureModel()
        let snapshot = RebalancingValuationSnapshot(
            holdings: [
                .init(symbol: "STOCK", name: "Stocks", quantity: 50, price: 1, averageCost: 1),
                .init(symbol: "BOND", name: "Bonds", quantity: 40, price: 1, averageCost: 1),
                .init(symbol: "OTHER", name: "Other", quantity: 10, price: 1, averageCost: 1),
            ],
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: nil,
            warnings: []
        )

        let overview = try engine.overview(portfolioId: "portfolio", model: model, snapshot: snapshot)
        let simulation = try engine.simulate(
            portfolioId: "portfolio",
            model: model,
            request: .init(modelId: model.id, modelRevision: model.revision),
            snapshot: snapshot
        )

        #expect(overview.totalDriftBasisPoints == 1000)
        #expect(overview.rows.last?.id == "unassigned")
        #expect(overview.rows.last?.children.first?.symbol == "OTHER")
        #expect(simulation.trades.first { $0.symbol == "OTHER" }?.side == .sell)
        #expect(simulation.trades.first { $0.symbol == "OTHER" }?.notional == 10)
        #expect(simulation.driftAfterBasisPoints == 0)
    }

    @Test
    func `stale model revision is rejected`() {
        let model = fixtureModel()
        let snapshot = fixtureSnapshot()

        #expect(throws: RebalancingEngineError.staleModel) {
            try engine.simulate(
                portfolioId: "portfolio",
                model: model,
                request: .init(modelId: model.id, modelRevision: model.revision - 1),
                snapshot: snapshot
            )
        }
    }

    @Test
    func `model requires bucket and leaf totals to match one hundred percent`() {
        let invalid = AllocationModel(
            id: "model",
            portfolioId: "portfolio",
            name: "Invalid",
            groupingMode: .custom,
            isActive: true,
            revision: 1,
            baseCurrency: "USD",
            buckets: [
                .init(
                    id: "stocks",
                    name: "Stocks",
                    targetBasisPoints: 6000,
                    leaves: [
                        .init(id: "stock", kind: .security, symbol: "STOCK", name: "Stocks", targetBasisPoints: 5000),
                    ]
                ),
            ],
            createdAt: "2026-07-14T12:00:00Z"
        )

        #expect(throws: RebalancingEngineError.self) {
            try engine.validate(invalid)
        }
    }

    @Test
    func `ticker validation rejects spreadsheet formulas`() {
        let model = fixtureModel()
        let invalid = AllocationModel(
            id: model.id,
            portfolioId: model.portfolioId,
            name: model.name,
            groupingMode: model.groupingMode,
            isActive: model.isActive,
            revision: model.revision,
            baseCurrency: model.baseCurrency,
            buckets: [
                .init(
                    id: "all",
                    name: "All",
                    targetBasisPoints: 10000,
                    leaves: [
                        .init(
                            id: "formula",
                            kind: .security,
                            symbol: "=HYPERLINK(\"https://example.invalid\")",
                            name: "Unsafe",
                            targetBasisPoints: 10000
                        ),
                    ]
                ),
            ],
            createdAt: model.createdAt
        )

        #expect(throws: RebalancingEngineError.self) {
            try engine.validate(invalid)
        }
    }

    private func fixtureModel() -> AllocationModel {
        AllocationModel(
            id: "model",
            portfolioId: "portfolio",
            name: "60 / 40",
            groupingMode: .custom,
            isActive: true,
            revision: 2,
            baseCurrency: "USD",
            buckets: [
                .init(
                    id: "stocks",
                    name: "Stocks",
                    targetBasisPoints: 6000,
                    leaves: [
                        .init(id: "stock", kind: .security, symbol: "STOCK", name: "Stocks", targetBasisPoints: 6000),
                    ]
                ),
                .init(
                    id: "bonds",
                    name: "Bonds",
                    targetBasisPoints: 4000,
                    leaves: [
                        .init(id: "bond", kind: .security, symbol: "BOND", name: "Bonds", targetBasisPoints: 4000),
                    ]
                ),
            ],
            createdAt: "2026-07-14T12:00:00Z"
        )
    }

    private func fixtureSnapshot() -> RebalancingValuationSnapshot {
        RebalancingValuationSnapshot(
            holdings: [
                .init(symbol: "STOCK", name: "Stocks", quantity: 60, price: 1, averageCost: 1),
                .init(symbol: "BOND", name: "Bonds", quantity: 40, price: 1, averageCost: 1),
            ],
            cash: 0,
            baseCurrency: "USD",
            priceQuality: .live,
            pricedAt: nil,
            warnings: []
        )
    }
}
