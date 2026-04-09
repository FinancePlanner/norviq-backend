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
