import Vapor
import StockPlanShared

typealias StockDetailsResponse = StockPlanShared.StockDetailsResponse
typealias QuoteResponse = StockPlanShared.QuoteResponse
typealias CompanyProfileResponse = StockPlanShared.CompanyProfileResponse
typealias PriceBarResponse = StockPlanShared.PriceBarResponse
typealias HistoryResponse = StockPlanShared.HistoryResponse
typealias SearchResultResponse = StockPlanShared.SearchResultResponse
typealias FxRateResponse = StockPlanShared.FxRateResponse
typealias QuoteBatchResponse = StockPlanShared.QuoteBatchResponse

enum BasicFinancialMetricValue: Content, Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }

        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported basic financial metric value."
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct BasicFinancialSeriesPoint: Content, Sendable, Equatable {
    let period: String
    let value: Double

    enum CodingKeys: String, CodingKey {
        case period
        case value = "v"
    }
}

struct BasicFinancialsResponse: Content, Sendable, Equatable {
    let symbol: String
    let metricType: String
    let metric: [String: BasicFinancialMetricValue]
    let series: [String: [String: [BasicFinancialSeriesPoint]]]
}

struct RatiosTTMResponse: Content, Sendable, Equatable {
    let symbol: String
    let grossProfitMarginTTM: Double?
    let ebitMarginTTM: Double?
    let ebitdaMarginTTM: Double?
    let operatingProfitMarginTTM: Double?
    let pretaxProfitMarginTTM: Double?
    let continuousOperationsProfitMarginTTM: Double?
    let netProfitMarginTTM: Double?
    let bottomLineProfitMarginTTM: Double?
    let receivablesTurnoverTTM: Double?
    let payablesTurnoverTTM: Double?
    let inventoryTurnoverTTM: Double?
    let fixedAssetTurnoverTTM: Double?
    let assetTurnoverTTM: Double?
    let currentRatioTTM: Double?
    let quickRatioTTM: Double?
    let solvencyRatioTTM: Double?
    let cashRatioTTM: Double?
    let priceToEarningsRatioTTM: Double?
    let priceToEarningsGrowthRatioTTM: Double?
    let forwardPriceToEarningsGrowthRatioTTM: Double?
    let priceToBookRatioTTM: Double?
    let priceToSalesRatioTTM: Double?
    let priceToFreeCashFlowRatioTTM: Double?
    let priceToOperatingCashFlowRatioTTM: Double?
    let debtToAssetsRatioTTM: Double?
    let debtToEquityRatioTTM: Double?
    let debtToCapitalRatioTTM: Double?
    let longTermDebtToCapitalRatioTTM: Double?
    let financialLeverageRatioTTM: Double?
    let workingCapitalTurnoverRatioTTM: Double?
    let operatingCashFlowRatioTTM: Double?
    let operatingCashFlowSalesRatioTTM: Double?
    let freeCashFlowOperatingCashFlowRatioTTM: Double?
    let debtServiceCoverageRatioTTM: Double?
    let interestCoverageRatioTTM: Double?
    let shortTermOperatingCashFlowCoverageRatioTTM: Double?
    let operatingCashFlowCoverageRatioTTM: Double?
    let capitalExpenditureCoverageRatioTTM: Double?
    let dividendPaidAndCapexCoverageRatioTTM: Double?
    let dividendPayoutRatioTTM: Double?
    let dividendYieldTTM: Double?
    let enterpriseValueTTM: Double?
    let revenuePerShareTTM: Double?
    let netIncomePerShareTTM: Double?
    let interestDebtPerShareTTM: Double?
    let cashPerShareTTM: Double?
    let bookValuePerShareTTM: Double?
    let tangibleBookValuePerShareTTM: Double?
    let shareholdersEquityPerShareTTM: Double?
    let operatingCashFlowPerShareTTM: Double?
    let capexPerShareTTM: Double?
    let freeCashFlowPerShareTTM: Double?
    let netIncomePerEBTTTM: Double?
    let ebtPerEbitTTM: Double?
    let priceToFairValueTTM: Double?
    let debtToMarketCapTTM: Double?
    let effectiveTaxRateTTM: Double?
    let enterpriseValueMultipleTTM: Double?
}

struct BalanceSheetStatementResponse: Content, Sendable, Equatable {
    let date: String
    let symbol: String
    let reportedCurrency: String?
    let cik: String?
    let filingDate: String?
    let acceptedDate: String?
    let fiscalYear: String?
    let period: String?
    let cashAndCashEquivalents: Double?
    let shortTermInvestments: Double?
    let cashAndShortTermInvestments: Double?
    let netReceivables: Double?
    let accountsReceivables: Double?
    let otherReceivables: Double?
    let inventory: Double?
    let prepaids: Double?
    let otherCurrentAssets: Double?
    let totalCurrentAssets: Double?
    let propertyPlantEquipmentNet: Double?
    let goodwill: Double?
    let intangibleAssets: Double?
    let goodwillAndIntangibleAssets: Double?
    let longTermInvestments: Double?
    let taxAssets: Double?
    let otherNonCurrentAssets: Double?
    let totalNonCurrentAssets: Double?
    let otherAssets: Double?
    let totalAssets: Double?
    let totalPayables: Double?
    let accountPayables: Double?
    let otherPayables: Double?
    let accruedExpenses: Double?
    let shortTermDebt: Double?
    let capitalLeaseObligationsCurrent: Double?
    let taxPayables: Double?
    let deferredRevenue: Double?
    let otherCurrentLiabilities: Double?
    let totalCurrentLiabilities: Double?
    let longTermDebt: Double?
    let deferredRevenueNonCurrent: Double?
    let deferredTaxLiabilitiesNonCurrent: Double?
    let otherNonCurrentLiabilities: Double?
    let totalNonCurrentLiabilities: Double?
    let otherLiabilities: Double?
    let capitalLeaseObligations: Double?
    let totalLiabilities: Double?
    let treasuryStock: Double?
    let preferredStock: Double?
    let commonStock: Double?
    let retainedEarnings: Double?
    let additionalPaidInCapital: Double?
    let accumulatedOtherComprehensiveIncomeLoss: Double?
    let otherTotalStockholdersEquity: Double?
    let totalStockholdersEquity: Double?
    let totalEquity: Double?
    let minorityInterest: Double?
    let totalLiabilitiesAndTotalEquity: Double?
    let totalInvestments: Double?
    let totalDebt: Double?
    let netDebt: Double?
}

struct CashFlowStatementResponse: Content, Sendable, Equatable {
    let date: String
    let symbol: String
    let reportedCurrency: String?
    let cik: String?
    let filingDate: String?
    let acceptedDate: String?
    let fiscalYear: String?
    let period: String?
    let netIncome: Double?
    let depreciationAndAmortization: Double?
    let deferredIncomeTax: Double?
    let stockBasedCompensation: Double?
    let changeInWorkingCapital: Double?
    let accountsReceivables: Double?
    let inventory: Double?
    let accountsPayables: Double?
    let otherWorkingCapital: Double?
    let otherNonCashItems: Double?
    let netCashProvidedByOperatingActivities: Double?
    let investmentsInPropertyPlantAndEquipment: Double?
    let acquisitionsNet: Double?
    let purchasesOfInvestments: Double?
    let salesMaturitiesOfInvestments: Double?
    let otherInvestingActivities: Double?
    let netCashProvidedByInvestingActivities: Double?
    let netDebtIssuance: Double?
    let longTermNetDebtIssuance: Double?
    let shortTermNetDebtIssuance: Double?
    let netStockIssuance: Double?
    let netCommonStockIssuance: Double?
    let commonStockIssuance: Double?
    let commonStockRepurchased: Double?
    let netPreferredStockIssuance: Double?
    let netDividendsPaid: Double?
    let commonDividendsPaid: Double?
    let preferredDividendsPaid: Double?
    let otherFinancingActivities: Double?
    let netCashProvidedByFinancingActivities: Double?
    let effectOfForexChangesOnCash: Double?
    let netChangeInCash: Double?
    let cashAtEndOfPeriod: Double?
    let cashAtBeginningOfPeriod: Double?
    let operatingCashFlow: Double?
    let capitalExpenditure: Double?
    let freeCashFlow: Double?
    let incomeTaxesPaid: Double?
    let interestPaid: Double?
}

struct FinancialGrowthResponse: Content, Sendable, Equatable {
    let symbol: String
    let date: String
    let fiscalYear: String?
    let period: String?
    let reportedCurrency: String?
    let revenueGrowth: Double?
    let grossProfitGrowth: Double?
    let ebitgrowth: Double?
    let operatingIncomeGrowth: Double?
    let netIncomeGrowth: Double?
    let epsgrowth: Double?
    let epsdilutedGrowth: Double?
    let weightedAverageSharesGrowth: Double?
    let weightedAverageSharesDilutedGrowth: Double?
    let dividendsPerShareGrowth: Double?
    let operatingCashFlowGrowth: Double?
    let receivablesGrowth: Double?
    let inventoryGrowth: Double?
    let assetGrowth: Double?
    let bookValueperShareGrowth: Double?
    let debtGrowth: Double?
    let rdexpenseGrowth: Double?
    let sgaexpensesGrowth: Double?
    let freeCashFlowGrowth: Double?
    let tenYRevenueGrowthPerShare: Double?
    let fiveYRevenueGrowthPerShare: Double?
    let threeYRevenueGrowthPerShare: Double?
    let tenYOperatingCFGrowthPerShare: Double?
    let fiveYOperatingCFGrowthPerShare: Double?
    let threeYOperatingCFGrowthPerShare: Double?
    let tenYNetIncomeGrowthPerShare: Double?
    let fiveYNetIncomeGrowthPerShare: Double?
    let threeYNetIncomeGrowthPerShare: Double?
    let tenYShareholdersEquityGrowthPerShare: Double?
    let fiveYShareholdersEquityGrowthPerShare: Double?
    let threeYShareholdersEquityGrowthPerShare: Double?
    let tenYDividendperShareGrowthPerShare: Double?
    let fiveYDividendperShareGrowthPerShare: Double?
    let threeYDividendperShareGrowthPerShare: Double?
    let ebitdaGrowth: Double?
    let growthCapitalExpenditure: Double?
    let tenYBottomLineNetIncomeGrowthPerShare: Double?
    let fiveYBottomLineNetIncomeGrowthPerShare: Double?
    let threeYBottomLineNetIncomeGrowthPerShare: Double?
}

struct AnalystEstimatesResponse: Content, Sendable, Equatable {
    let symbol: String
    let date: String
    let revenueLow: Double?
    let revenueHigh: Double?
    let revenueAvg: Double?
    let ebitdaLow: Double?
    let ebitdaHigh: Double?
    let ebitdaAvg: Double?
    let ebitLow: Double?
    let ebitHigh: Double?
    let ebitAvg: Double?
    let netIncomeLow: Double?
    let netIncomeHigh: Double?
    let netIncomeAvg: Double?
    let sgaExpenseLow: Double?
    let sgaExpenseHigh: Double?
    let sgaExpenseAvg: Double?
    let epsAvg: Double?
    let epsHigh: Double?
    let epsLow: Double?
    let numAnalystsRevenue: Int?
    let numAnalystsEps: Int?
}

struct RatiosResponse: Content, Sendable, Equatable {
    let symbol: String
    let date: String
    let fiscalYear: String?
    let period: String?
    let reportedCurrency: String?
    let grossProfitMargin: Double?
    let ebitMargin: Double?
    let ebitdaMargin: Double?
    let operatingProfitMargin: Double?
    let pretaxProfitMargin: Double?
    let continuousOperationsProfitMargin: Double?
    let netProfitMargin: Double?
    let bottomLineProfitMargin: Double?
    let receivablesTurnover: Double?
    let payablesTurnover: Double?
    let inventoryTurnover: Double?
    let fixedAssetTurnover: Double?
    let assetTurnover: Double?
    let currentRatio: Double?
    let quickRatio: Double?
    let solvencyRatio: Double?
    let cashRatio: Double?
    let priceToEarningsRatio: Double?
    let priceToEarningsGrowthRatio: Double?
    let forwardPriceToEarningsGrowthRatio: Double?
    let priceToBookRatio: Double?
    let priceToSalesRatio: Double?
    let priceToFreeCashFlowRatio: Double?
    let priceToOperatingCashFlowRatio: Double?
    let debtToAssetsRatio: Double?
    let debtToEquityRatio: Double?
    let debtToCapitalRatio: Double?
    let longTermDebtToCapitalRatio: Double?
    let financialLeverageRatio: Double?
    let workingCapitalTurnoverRatio: Double?
    let operatingCashFlowRatio: Double?
    let operatingCashFlowSalesRatio: Double?
    let freeCashFlowOperatingCashFlowRatio: Double?
    let debtServiceCoverageRatio: Double?
    let interestCoverageRatio: Double?
    let shortTermOperatingCashFlowCoverageRatio: Double?
    let operatingCashFlowCoverageRatio: Double?
    let capitalExpenditureCoverageRatio: Double?
    let dividendPaidAndCapexCoverageRatio: Double?
    let dividendPayoutRatio: Double?
    let dividendYield: Double?
    let dividendYieldPercentage: Double?
    let revenuePerShare: Double?
    let netIncomePerShare: Double?
    let interestDebtPerShare: Double?
    let cashPerShare: Double?
    let bookValuePerShare: Double?
    let tangibleBookValuePerShare: Double?
    let shareholdersEquityPerShare: Double?
    let operatingCashFlowPerShare: Double?
    let capexPerShare: Double?
    let freeCashFlowPerShare: Double?
    let netIncomePerEBT: Double?
    let ebtPerEbit: Double?
    let priceToFairValue: Double?
    let debtToMarketCap: Double?
    let effectiveTaxRate: Double?
    let enterpriseValueMultiple: Double?
}

struct HistoricalSectorPerformanceResponse: Content, Sendable, Equatable {
    let date: String
    let sector: String
    let exchange: String
    let averageChange: Double
}

struct GradesConsensusResponse: Content, Sendable, Equatable {
    let symbol: String
    let strongBuy: Int?
    let buy: Int?
    let hold: Int?
    let sell: Int?
    let strongSell: Int?
    let consensus: String?
}

struct EarningsResponse: Content, Sendable, Equatable {
    let symbol: String
    let date: String
    let epsActual: Double?
    let epsEstimated: Double?
    let revenueActual: Double?
    let revenueEstimated: Double?
    let lastUpdated: String?
}

struct YearlyProjectionResponse: Content, Sendable, Equatable {
    let year: Int
    let revenue: Double
    let revenueGrowth: Double
    let netIncome: Double
    let netIncomeGrowth: Double
    let netMargin: Double
    let eps: Double
    let fcf: Double?
    let fcfMargin: Double?
}

struct StockAnalysisMetricsResponse: Content, Sendable, Equatable {
    let symbol: String
    let ttmPE: Double?
    let forwardPE: Double?
    let twoYearForwardPE: Double?
    let ttmEPSGrowth: Double?
    let currentYearExpectedEPSGrowth: Double?
    let nextYearEPSGrowth: Double?
    let ttmRevenueGrowth: Double?
    let currentYearExpectedRevenueGrowth: Double?
    let nextYearRevenueGrowth: Double?
    let grossMargin: Double?
    let netMargin: Double?
    let ttmPEGRatio: Double?
    let lastYearEPSGrowth: Double?
    let ttmVsNTMEPSGrowth: Double?
    let currentQuarterEPSGrowthVsPreviousYear: Double?
    let twoYearStackExpectedEPSGrowth: Double?
    let lastYearRevenueGrowth: Double?
    let ttmVsNTMRevenueGrowth: Double?
    let currentQuarterRevenueGrowthVsPreviousYear: Double?
    let twoYearStackExpectedRevenueGrowth: Double?

    // Forecast / DCF metrics
    let currentPrice: Double?
    let marketCap: Double?
    let sharesOutstanding: Double?
    let baseYear: Int?
    let yearlyProjections: [YearlyProjectionResponse]?
    let wacc: Double?
    let terminalGrowthRate: Double?
    let terminalMargin: Double?
    let exitPELow: Double?
    let exitPEHigh: Double?
    let dcfBasePrice: Double?
    let dcfBearPrice: Double?
    let dcfBullPrice: Double?
    let netDebt: Double?
}
