import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

struct ChartBuilderRegistryTests {
    @Test func resolverAndCatalogCoverIdenticalKeySets() {
        let catalogKeys = Set(ChartBuilderMetricCatalog.all.map(\.key))
        let resolverKeys = Set(ChartBuilderMetricResolver.bindings.keys)
        #expect(
            catalogKeys.symmetricDifference(resolverKeys).isEmpty,
            "drift: \(catalogKeys.symmetricDifference(resolverKeys).sorted())"
        )
    }

    @Test func everyCatalogKeyExtractsFromFullyPopulatedRow() throws {
        let row = try makeFullyPopulatedRow()
        for descriptor in ChartBuilderMetricCatalog.all {
            let binding = try #require(
                ChartBuilderMetricResolver.binding(for: descriptor.key),
                "missing binding: \(descriptor.key)"
            )
            #expect(binding.extract(row) != nil, "extractor returned nil: \(descriptor.key)")
        }
    }

    @Test func ttmComponentRecipesResolveToFlowMetrics() throws {
        for (key, binding) in ChartBuilderMetricResolver.bindings {
            guard let components = binding.ttmComponents else { continue }
            for componentKey in [components.numerator, components.denominator] {
                let descriptor = try #require(
                    ChartBuilderMetricCatalog.byKey[componentKey],
                    "\(key): unknown TTM component \(componentKey)"
                )
                #expect(descriptor.aggregation == .flow, "\(key): TTM component \(componentKey) is not a flow metric")
            }
        }
    }

    @Test func everyTTMSupportingRatioHasComponentRecipe() {
        for descriptor in ChartBuilderMetricCatalog.all
            where descriptor.aggregation == .ratio && descriptor.supportsTTM
        {
            let binding = ChartBuilderMetricResolver.binding(for: descriptor.key)
            #expect(binding?.ttmComponents != nil, "\(descriptor.key) supports TTM but has no component recipe")
        }
    }

    @Test func ttmMarginsFetchTheirComponentSources() {
        let grossMarginSources = ChartBuilderMetricResolver.requiredSources(
            for: ["grossProfitMargin"],
            period: .ttm
        )
        #expect(grossMarginSources == [.income])

        let fcfMarginSources = ChartBuilderMetricResolver.requiredSources(
            for: ["fcfMargin"],
            period: .ttm
        )
        #expect(fcfMarginSources == [.income, .cashFlow])
    }

    // MARK: - Fixture

    /// Decodes each statement DTO from a superset dictionary containing every
    /// catalog key (plus the raw DTO property names behind renamed keys) so
    /// every extractor finds a value.
    private func makeFullyPopulatedRow() throws -> ChartBuilderPeriodRow {
        var fields: [String: Any] = [
            "symbol": "AAPL",
            "date": "2024-09-28",
            "reportedCurrency": "USD",
            "fiscalYear": "2024",
            "period": "FY",
        ]
        for (index, descriptor) in ChartBuilderMetricCatalog.all.enumerated() {
            fields[descriptor.key] = Double(index + 1)
        }
        // Renamed cash-flow working-capital keys → raw DTO property names.
        fields["accountsReceivables"] = 1.0
        fields["inventory"] = 2.0
        fields["accountsPayables"] = 3.0
        // Derived metrics need their inputs populated.
        fields["freeCashFlow"] = 100.0
        fields["revenue"] = 400.0
        fields["weightedAverageShsOutDil"] = 50.0

        let data = try JSONSerialization.data(withJSONObject: fields)
        let decoder = JSONDecoder()
        return try ChartBuilderPeriodRow(
            income: decoder.decode(IncomeStatementResponse.self, from: data),
            balance: decoder.decode(BalanceSheetStatementResponse.self, from: data),
            cashFlow: decoder.decode(CashFlowStatementResponse.self, from: data),
            ratios: decoder.decode(RatiosResponse.self, from: data),
            growth: decoder.decode(FinancialGrowthResponse.self, from: data)
        )
    }
}
