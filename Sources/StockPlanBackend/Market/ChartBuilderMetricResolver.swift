import Foundation
import StockPlanShared

/// Statement families a chart-builder metric can draw from.
enum ChartBuilderSource: String, CaseIterable {
    case income
    case balance
    case cashFlow
    case ratios
    case growth
}

/// All statement rows for one symbol and one reporting period, matched by
/// fiscal year (and fiscal period for quarterly data).
struct ChartBuilderPeriodRow {
    var income: IncomeStatementResponse?
    var balance: BalanceSheetStatementResponse?
    var cashFlow: CashFlowStatementResponse?
    var ratios: RatiosResponse?
    var growth: FinancialGrowthResponse?
}

struct ChartBuilderMetricBinding {
    let sources: Set<ChartBuilderSource>
    /// Numerator/denominator metric keys used to recompute a ratio for TTM
    /// (both must resolve to `flow` metrics). Nil for non-TTM ratios.
    let ttmComponents: (numerator: String, denominator: String)?
    let extract: @Sendable (ChartBuilderPeriodRow) -> Double?
}

/// Maps every `ChartBuilderMetricCatalog` key to the statement source(s) it
/// needs and a closure extracting its value from one period's rows.
enum ChartBuilderMetricResolver {
    static func binding(for key: String) -> ChartBuilderMetricBinding? {
        bindings[key]
    }

    static func requiredSources(
        for keys: [String],
        period: ChartBuilderPeriodKind
    ) -> Set<ChartBuilderSource> {
        keys.reduce(into: Set<ChartBuilderSource>()) { partial, key in
            guard let binding = bindings[key] else { return }

            if period == .ttm, let components = binding.ttmComponents {
                for componentKey in [components.numerator, components.denominator] {
                    if let componentBinding = bindings[componentKey] {
                        partial.formUnion(componentBinding.sources)
                    }
                }
            } else {
                partial.formUnion(binding.sources)
            }
        }
    }

    // MARK: - Binding helpers

    private static func income(
        _ extract: @escaping @Sendable (IncomeStatementResponse) -> Double?
    ) -> ChartBuilderMetricBinding {
        ChartBuilderMetricBinding(sources: [.income], ttmComponents: nil) { $0.income.flatMap(extract) }
    }

    private static func balance(
        _ extract: @escaping @Sendable (BalanceSheetStatementResponse) -> Double?
    ) -> ChartBuilderMetricBinding {
        ChartBuilderMetricBinding(sources: [.balance], ttmComponents: nil) { $0.balance.flatMap(extract) }
    }

    private static func cashFlow(
        _ extract: @escaping @Sendable (CashFlowStatementResponse) -> Double?
    ) -> ChartBuilderMetricBinding {
        ChartBuilderMetricBinding(sources: [.cashFlow], ttmComponents: nil) { $0.cashFlow.flatMap(extract) }
    }

    private static func ratios(
        ttm: (numerator: String, denominator: String)? = nil,
        _ extract: @escaping @Sendable (RatiosResponse) -> Double?
    ) -> ChartBuilderMetricBinding {
        ChartBuilderMetricBinding(sources: [.ratios], ttmComponents: ttm) { $0.ratios.flatMap(extract) }
    }

    private static func growth(
        _ extract: @escaping @Sendable (FinancialGrowthResponse) -> Double?
    ) -> ChartBuilderMetricBinding {
        ChartBuilderMetricBinding(sources: [.growth], ttmComponents: nil) { $0.growth.flatMap(extract) }
    }

    // MARK: - Table

    static let bindings: [String: ChartBuilderMetricBinding] = [
        // Income statement
        "revenue": income { $0.revenue },
        "costOfRevenue": income { $0.costOfRevenue },
        "grossProfit": income { $0.grossProfit },
        "researchAndDevelopmentExpenses": income { $0.researchAndDevelopmentExpenses },
        "generalAndAdministrativeExpenses": income { $0.generalAndAdministrativeExpenses },
        "sellingAndMarketingExpenses": income { $0.sellingAndMarketingExpenses },
        "sellingGeneralAndAdministrativeExpenses": income { $0.sellingGeneralAndAdministrativeExpenses },
        "otherExpenses": income { $0.otherExpenses },
        "operatingExpenses": income { $0.operatingExpenses },
        "costAndExpenses": income { $0.costAndExpenses },
        "netInterestIncome": income { $0.netInterestIncome },
        "interestIncome": income { $0.interestIncome },
        "interestExpense": income { $0.interestExpense },
        "ebitda": income { $0.ebitda },
        "ebit": income { $0.ebit },
        "nonOperatingIncomeExcludingInterest": income { $0.nonOperatingIncomeExcludingInterest },
        "operatingIncome": income { $0.operatingIncome },
        "totalOtherIncomeExpensesNet": income { $0.totalOtherIncomeExpensesNet },
        "incomeBeforeTax": income { $0.incomeBeforeTax },
        "incomeTaxExpense": income { $0.incomeTaxExpense },
        "netIncomeFromContinuingOperations": income { $0.netIncomeFromContinuingOperations },
        "netIncomeFromDiscontinuedOperations": income { $0.netIncomeFromDiscontinuedOperations },
        "otherAdjustmentsToNetIncome": income { $0.otherAdjustmentsToNetIncome },
        "netIncome": income { $0.netIncome },
        "netIncomeDeductions": income { $0.netIncomeDeductions },
        "bottomLineNetIncome": income { $0.bottomLineNetIncome },
        "eps": income { $0.eps },
        "epsDiluted": income { $0.epsDiluted },
        "weightedAverageShsOut": income { $0.weightedAverageShsOut },
        "weightedAverageShsOutDil": income { $0.weightedAverageShsOutDil },

        // Balance sheet
        "cashAndCashEquivalents": balance { $0.cashAndCashEquivalents },
        "shortTermInvestments": balance { $0.shortTermInvestments },
        "cashAndShortTermInvestments": balance { $0.cashAndShortTermInvestments },
        "netReceivables": balance { $0.netReceivables },
        "accountsReceivables": balance { $0.accountsReceivables },
        "otherReceivables": balance { $0.otherReceivables },
        "inventory": balance { $0.inventory },
        "prepaids": balance { $0.prepaids },
        "otherCurrentAssets": balance { $0.otherCurrentAssets },
        "totalCurrentAssets": balance { $0.totalCurrentAssets },
        "propertyPlantEquipmentNet": balance { $0.propertyPlantEquipmentNet },
        "goodwill": balance { $0.goodwill },
        "intangibleAssets": balance { $0.intangibleAssets },
        "goodwillAndIntangibleAssets": balance { $0.goodwillAndIntangibleAssets },
        "longTermInvestments": balance { $0.longTermInvestments },
        "taxAssets": balance { $0.taxAssets },
        "otherNonCurrentAssets": balance { $0.otherNonCurrentAssets },
        "totalNonCurrentAssets": balance { $0.totalNonCurrentAssets },
        "otherAssets": balance { $0.otherAssets },
        "totalAssets": balance { $0.totalAssets },
        "totalPayables": balance { $0.totalPayables },
        "accountPayables": balance { $0.accountPayables },
        "otherPayables": balance { $0.otherPayables },
        "accruedExpenses": balance { $0.accruedExpenses },
        "shortTermDebt": balance { $0.shortTermDebt },
        "capitalLeaseOblationsCurrent": balance { $0.capitalLeaseOblationsCurrent },
        "taxPayables": balance { $0.taxPayables },
        "deferredRevenue": balance { $0.deferredRevenue },
        "otherCurrentLiabilities": balance { $0.otherCurrentLiabilities },
        "totalCurrentLiabilities": balance { $0.totalCurrentLiabilities },
        "longTermDebt": balance { $0.longTermDebt },
        "deferredRevenueNonCurrent": balance { $0.deferredRevenueNonCurrent },
        "deferredTaxLiabilitiesNonCurrent": balance { $0.deferredTaxLiabilitiesNonCurrent },
        "otherNonCurrentLiabilities": balance { $0.otherNonCurrentLiabilities },
        "totalNonCurrentLiabilities": balance { $0.totalNonCurrentLiabilities },
        "otherLiabilities": balance { $0.otherLiabilities },
        "capitalLeaseObligations": balance { $0.capitalLeaseObligations },
        "totalLiabilities": balance { $0.totalLiabilities },
        "treasuryStock": balance { $0.treasuryStock },
        "preferredStock": balance { $0.preferredStock },
        "commonStock": balance { $0.commonStock },
        "retainedEarnings": balance { $0.retainedEarnings },
        "additionalPaidInCapital": balance { $0.additionalPaidInCapital },
        "accumulatedOtherComprehensiveIncomeLoss": balance { $0.accumulatedOtherComprehensiveIncomeLoss },
        "otherTotalStockholdersEquity": balance { $0.otherTotalStockholdersEquity },
        "totalStockholdersEquity": balance { $0.totalStockholdersEquity },
        "totalEquity": balance { $0.totalEquity },
        "minorityInterest": balance { $0.minorityInterest },
        "totalLiabilitiesAndTotalEquity": balance { $0.totalLiabilitiesAndTotalEquity },
        "totalInvestments": balance { $0.totalInvestments },
        "totalDebt": balance { $0.totalDebt },
        "netDebt": balance { $0.netDebt },

        // Cash flow
        "depreciationAndAmortization": cashFlow { $0.depreciationAndAmortization },
        "deferredIncomeTax": cashFlow { $0.deferredIncomeTax },
        "stockBasedCompensation": cashFlow { $0.stockBasedCompensation },
        "changeInWorkingCapital": cashFlow { $0.changeInWorkingCapital },
        "changeInAccountsReceivables": cashFlow { $0.accountsReceivables },
        "changeInInventory": cashFlow { $0.inventory },
        "changeInAccountsPayables": cashFlow { $0.accountsPayables },
        "otherWorkingCapital": cashFlow { $0.otherWorkingCapital },
        "otherNonCashItems": cashFlow { $0.otherNonCashItems },
        "netCashProvidedByOperatingActivities": cashFlow { $0.netCashProvidedByOperatingActivities },
        "investmentsInPropertyPlantAndEquipment": cashFlow { $0.investmentsInPropertyPlantAndEquipment },
        "acquisitionsNet": cashFlow { $0.acquisitionsNet },
        "purchasesOfInvestments": cashFlow { $0.purchasesOfInvestments },
        "salesMaturitiesOfInvestments": cashFlow { $0.salesMaturitiesOfInvestments },
        "otherInvestingActivities": cashFlow { $0.otherInvestingActivities },
        "netCashProvidedByInvestingActivities": cashFlow { $0.netCashProvidedByInvestingActivities },
        "netDebtIssuance": cashFlow { $0.netDebtIssuance },
        "longTermNetDebtIssuance": cashFlow { $0.longTermNetDebtIssuance },
        "shortTermNetDebtIssuance": cashFlow { $0.shortTermNetDebtIssuance },
        "netStockIssuance": cashFlow { $0.netStockIssuance },
        "netCommonStockIssuance": cashFlow { $0.netCommonStockIssuance },
        "commonStockIssuance": cashFlow { $0.commonStockIssuance },
        "commonStockRepurchased": cashFlow { $0.commonStockRepurchased },
        "netPreferredStockIssuance": cashFlow { $0.netPreferredStockIssuance },
        "netDividendsPaid": cashFlow { $0.netDividendsPaid },
        "commonDividendsPaid": cashFlow { $0.commonDividendsPaid },
        "preferredDividendsPaid": cashFlow { $0.preferredDividendsPaid },
        "otherFinancingActivities": cashFlow { $0.otherFinancingActivities },
        "netCashProvidedByFinancingActivities": cashFlow { $0.netCashProvidedByFinancingActivities },
        "effectOfForexChangesOnCash": cashFlow { $0.effectOfForexChangesOnCash },
        "netChangeInCash": cashFlow { $0.netChangeInCash },
        "operatingCashFlow": cashFlow { $0.operatingCashFlow },
        "capitalExpenditure": cashFlow { $0.capitalExpenditure },
        "freeCashFlow": cashFlow { $0.freeCashFlow },
        "incomeTaxesPaid": cashFlow { $0.incomeTaxesPaid },
        "interestPaid": cashFlow { $0.interestPaid },

        // Ratios — margins carry TTM recompute recipes
        "grossProfitMargin": ratios(ttm: ("grossProfit", "revenue")) { $0.grossProfitMargin },
        "ebitMargin": ratios(ttm: ("ebit", "revenue")) { $0.ebitMargin },
        "ebitdaMargin": ratios(ttm: ("ebitda", "revenue")) { $0.ebitdaMargin },
        "operatingProfitMargin": ratios(ttm: ("operatingIncome", "revenue")) { $0.operatingProfitMargin },
        "pretaxProfitMargin": ratios(ttm: ("incomeBeforeTax", "revenue")) { $0.pretaxProfitMargin },
        "netProfitMargin": ratios(ttm: ("netIncome", "revenue")) { $0.netProfitMargin },
        "continuousOperationsProfitMargin": ratios { $0.continuousOperationsProfitMargin },
        "bottomLineProfitMargin": ratios { $0.bottomLineProfitMargin },
        "receivablesTurnover": ratios { $0.receivablesTurnover },
        "payablesTurnover": ratios { $0.payablesTurnover },
        "inventoryTurnover": ratios { $0.inventoryTurnover },
        "fixedAssetTurnover": ratios { $0.fixedAssetTurnover },
        "assetTurnover": ratios { $0.assetTurnover },
        "currentRatio": ratios { $0.currentRatio },
        "quickRatio": ratios { $0.quickRatio },
        "solvencyRatio": ratios { $0.solvencyRatio },
        "cashRatio": ratios { $0.cashRatio },
        "priceToEarningsRatio": ratios { $0.priceToEarningsRatio },
        "priceToEarningsGrowthRatio": ratios { $0.priceToEarningsGrowthRatio },
        "forwardPriceToEarningsGrowthRatio": ratios { $0.forwardPriceToEarningsGrowthRatio },
        "priceToBookRatio": ratios { $0.priceToBookRatio },
        "priceToSalesRatio": ratios { $0.priceToSalesRatio },
        "priceToFreeCashFlowRatio": ratios { $0.priceToFreeCashFlowRatio },
        "priceToOperatingCashFlowRatio": ratios { $0.priceToOperatingCashFlowRatio },
        "debtToAssetsRatio": ratios { $0.debtToAssetsRatio },
        "debtToEquityRatio": ratios { $0.debtToEquityRatio },
        "debtToCapitalRatio": ratios { $0.debtToCapitalRatio },
        "longTermDebtToCapitalRatio": ratios { $0.longTermDebtToCapitalRatio },
        "financialLeverageRatio": ratios { $0.financialLeverageRatio },
        "workingCapitalTurnoverRatio": ratios { $0.workingCapitalTurnoverRatio },
        "operatingCashFlowRatio": ratios { $0.operatingCashFlowRatio },
        "operatingCashFlowSalesRatio": ratios { $0.operatingCashFlowSalesRatio },
        "freeCashFlowOperatingCashFlowRatio": ratios { $0.freeCashFlowOperatingCashFlowRatio },
        "debtServiceCoverageRatio": ratios { $0.debtServiceCoverageRatio },
        "interestCoverageRatio": ratios { $0.interestCoverageRatio },
        "shortTermOperatingCashFlowCoverageRatio": ratios { $0.shortTermOperatingCashFlowCoverageRatio },
        "operatingCashFlowCoverageRatio": ratios { $0.operatingCashFlowCoverageRatio },
        "capitalExpenditureCoverageRatio": ratios { $0.capitalExpenditureCoverageRatio },
        "dividendPaidAndCapexCoverageRatio": ratios { $0.dividendPaidAndCapexCoverageRatio },
        "dividendPayoutRatio": ratios { $0.dividendPayoutRatio },
        "dividendYield": ratios { $0.dividendYield },
        "effectiveTaxRate": ratios { $0.effectiveTaxRate },
        "netIncomePerEBT": ratios { $0.netIncomePerEBT },
        "ebtPerEbit": ratios { $0.ebtPerEbit },
        "priceToFairValue": ratios { $0.priceToFairValue },
        "debtToMarketCap": ratios { $0.debtToMarketCap },
        "enterpriseValueMultiple": ratios { $0.enterpriseValueMultiple },
        "revenuePerShare": ratios { $0.revenuePerShare },
        "netIncomePerShare": ratios { $0.netIncomePerShare },
        "interestDebtPerShare": ratios { $0.interestDebtPerShare },
        "cashPerShare": ratios { $0.cashPerShare },
        "bookValuePerShare": ratios { $0.bookValuePerShare },
        "tangibleBookValuePerShare": ratios { $0.tangibleBookValuePerShare },
        "shareholdersEquityPerShare": ratios { $0.shareholdersEquityPerShare },
        "operatingCashFlowPerShare": ratios { $0.operatingCashFlowPerShare },
        "capexPerShare": ratios { $0.capexPerShare },
        "freeCashFlowPerShare": ratios { $0.freeCashFlowPerShare },

        // Growth
        "revenueGrowth": growth { $0.revenueGrowth },
        "grossProfitGrowth": growth { $0.grossProfitGrowth },
        "ebitgrowth": growth { $0.ebitgrowth },
        "operatingIncomeGrowth": growth { $0.operatingIncomeGrowth },
        "netIncomeGrowth": growth { $0.netIncomeGrowth },
        "epsgrowth": growth { $0.epsgrowth },
        "epsdilutedGrowth": growth { $0.epsdilutedGrowth },
        "weightedAverageSharesGrowth": growth { $0.weightedAverageSharesGrowth },
        "weightedAverageSharesDilutedGrowth": growth { $0.weightedAverageSharesDilutedGrowth },
        "dividendsPerShareGrowth": growth { $0.dividendsPerShareGrowth },
        "operatingCashFlowGrowth": growth { $0.operatingCashFlowGrowth },
        "receivablesGrowth": growth { $0.receivablesGrowth },
        "inventoryGrowth": growth { $0.inventoryGrowth },
        "assetGrowth": growth { $0.assetGrowth },
        "bookValueperShareGrowth": growth { $0.bookValueperShareGrowth },
        "debtGrowth": growth { $0.debtGrowth },
        "rdexpenseGrowth": growth { $0.rdexpenseGrowth },
        "sgaexpensesGrowth": growth { $0.sgaexpensesGrowth },
        "freeCashFlowGrowth": growth { $0.freeCashFlowGrowth },
        "ebitdaGrowth": growth { $0.ebitdaGrowth },
        "growthCapitalExpenditure": growth { $0.growthCapitalExpenditure },
        "tenYRevenueGrowthPerShare": growth { $0.tenYRevenueGrowthPerShare },
        "fiveYRevenueGrowthPerShare": growth { $0.fiveYRevenueGrowthPerShare },
        "threeYRevenueGrowthPerShare": growth { $0.threeYRevenueGrowthPerShare },
        "tenYOperatingCFGrowthPerShare": growth { $0.tenYOperatingCFGrowthPerShare },
        "fiveYOperatingCFGrowthPerShare": growth { $0.fiveYOperatingCFGrowthPerShare },
        "threeYOperatingCFGrowthPerShare": growth { $0.threeYOperatingCFGrowthPerShare },
        "tenYNetIncomeGrowthPerShare": growth { $0.tenYNetIncomeGrowthPerShare },
        "fiveYNetIncomeGrowthPerShare": growth { $0.fiveYNetIncomeGrowthPerShare },
        "threeYNetIncomeGrowthPerShare": growth { $0.threeYNetIncomeGrowthPerShare },
        "tenYShareholdersEquityGrowthPerShare": growth { $0.tenYShareholdersEquityGrowthPerShare },
        "fiveYShareholdersEquityGrowthPerShare": growth { $0.fiveYShareholdersEquityGrowthPerShare },
        "threeYShareholdersEquityGrowthPerShare": growth { $0.threeYShareholdersEquityGrowthPerShare },
        "tenYDividendperShareGrowthPerShare": growth { $0.tenYDividendperShareGrowthPerShare },
        "fiveYDividendperShareGrowthPerShare": growth { $0.fiveYDividendperShareGrowthPerShare },
        "threeYDividendperShareGrowthPerShare": growth { $0.threeYDividendperShareGrowthPerShare },
        "tenYBottomLineNetIncomeGrowthPerShare": growth { $0.tenYBottomLineNetIncomeGrowthPerShare },
        "fiveYBottomLineNetIncomeGrowthPerShare": growth { $0.fiveYBottomLineNetIncomeGrowthPerShare },
        "threeYBottomLineNetIncomeGrowthPerShare": growth { $0.threeYBottomLineNetIncomeGrowthPerShare },

        // Derived
        "fcfMargin": ChartBuilderMetricBinding(
            sources: [.income, .cashFlow],
            ttmComponents: ("freeCashFlow", "revenue")
        ) { row in
            guard let fcf = row.cashFlow?.freeCashFlow,
                  let revenue = row.income?.revenue,
                  revenue != 0
            else { return nil }
            return fcf / revenue
        },
        "fcfPerShare": ChartBuilderMetricBinding(
            sources: [.income, .cashFlow],
            ttmComponents: nil
        ) { row in
            guard let fcf = row.cashFlow?.freeCashFlow,
                  let shares = row.income?.weightedAverageShsOutDil,
                  shares != 0
            else { return nil }
            return fcf / shares
        },
    ]
}
