import Foundation
import Vapor

public struct HistoricalSectorPerformanceResponse: Content, Sendable, Equatable {
    public let date: String
    public let sector: String
    public let exchange: String
    public let averageChange: Double

    public init(date: String, sector: String, exchange: String, averageChange: Double) {
        self.date = date
        self.sector = sector
        self.exchange = exchange
        self.averageChange = averageChange
    }
}

public struct GradesConsensusResponse: Content, Sendable, Equatable {
    public let symbol: String
    public let strongBuy: Int?
    public let buy: Int?
    public let hold: Int?
    public let sell: Int?
    public let strongSell: Int?
    public let consensus: String?

    public init(
        symbol: String,
        strongBuy: Int?,
        buy: Int?,
        hold: Int?,
        sell: Int?,
        strongSell: Int?,
        consensus: String?
    ) {
        self.symbol = symbol
        self.strongBuy = strongBuy
        self.buy = buy
        self.hold = hold
        self.sell = sell
        self.strongSell = strongSell
        self.consensus = consensus
    }
}

public struct EarningsResponse: Content, Sendable, Equatable {
    public let symbol: String
    public let date: String
    public let epsActual: Double?
    public let epsEstimated: Double?
    public let revenueActual: Double?
    public let revenueEstimated: Double?
    public let lastUpdated: String?
    public let surprisePercent: Double?
    public let hasTranscript: Bool

    public init(
        symbol: String,
        date: String,
        epsActual: Double?,
        epsEstimated: Double?,
        revenueActual: Double?,
        revenueEstimated: Double?,
        lastUpdated: String?,
        surprisePercent: Double?,
        hasTranscript: Bool
    ) {
        self.symbol = symbol
        self.date = date
        self.epsActual = epsActual
        self.epsEstimated = epsEstimated
        self.revenueActual = revenueActual
        self.revenueEstimated = revenueEstimated
        self.lastUpdated = lastUpdated
        self.surprisePercent = surprisePercent
        self.hasTranscript = hasTranscript
    }
}

public struct EarningsTranscriptResponse: Content, Sendable, Equatable {
    public let symbol: String
    public let date: String
    public let year: Int
    public let quarter: Int
    public let period: String?
    public let content: String
    public let provider: String

    public init(
        symbol: String,
        date: String,
        year: Int,
        quarter: Int,
        period: String?,
        content: String,
        provider: String
    ) {
        self.symbol = symbol
        self.date = date
        self.year = year
        self.quarter = quarter
        self.period = period
        self.content = content
        self.provider = provider
    }
}

public struct YearlyProjectionResponse: Content, Sendable, Equatable {
    public let year: Int
    public let revenue: Double
    public let revenueGrowth: Double
    public let netIncome: Double
    public let netIncomeGrowth: Double
    public let netMargin: Double
    public let eps: Double
    public let fcf: Double?
    public let fcfMargin: Double?

    public init(
        year: Int,
        revenue: Double,
        revenueGrowth: Double,
        netIncome: Double,
        netIncomeGrowth: Double,
        netMargin: Double,
        eps: Double,
        fcf: Double?,
        fcfMargin: Double?
    ) {
        self.year = year
        self.revenue = revenue
        self.revenueGrowth = revenueGrowth
        self.netIncome = netIncome
        self.netIncomeGrowth = netIncomeGrowth
        self.netMargin = netMargin
        self.eps = eps
        self.fcf = fcf
        self.fcfMargin = fcfMargin
    }
}

public struct StockAnalysisMetricsResponse: Content, Sendable, Equatable {
    public let symbol: String
    public let ttmPE: Double?
    public let forwardPE: Double?
    public let twoYearForwardPE: Double?
    public let ttmEPSGrowth: Double?
    public let currentYearExpectedEPSGrowth: Double?
    public let nextYearEPSGrowth: Double?
    public let ttmRevenueGrowth: Double?
    public let currentYearExpectedRevenueGrowth: Double?
    public let nextYearRevenueGrowth: Double?
    public let grossMargin: Double?
    public let netMargin: Double?
    public let ttmPEGRatio: Double?
    public let lastYearEPSGrowth: Double?
    public let ttmVsNTMEPSGrowth: Double?
    public let currentQuarterEPSGrowthVsPreviousYear: Double?
    public let twoYearStackExpectedEPSGrowth: Double?
    public let lastYearRevenueGrowth: Double?
    public let ttmVsNTMRevenueGrowth: Double?
    public let currentQuarterRevenueGrowthVsPreviousYear: Double?
    public let twoYearStackExpectedRevenueGrowth: Double?
    public let currentPrice: Double?
    public let marketCap: Double?
    public let sharesOutstanding: Double?
    public let baseYear: Int?
    public let yearlyProjections: [YearlyProjectionResponse]?
    public let wacc: Double?
    public let terminalGrowthRate: Double?
    public let terminalMargin: Double?
    public let exitPELow: Double?
    public let exitPEHigh: Double?
    public let dcfBasePrice: Double?
    public let dcfBearPrice: Double?
    public let dcfBullPrice: Double?
    public let netDebt: Double?

    public init(
        symbol: String,
        ttmPE: Double?,
        forwardPE: Double?,
        twoYearForwardPE: Double?,
        ttmEPSGrowth: Double?,
        currentYearExpectedEPSGrowth: Double?,
        nextYearEPSGrowth: Double?,
        ttmRevenueGrowth: Double?,
        currentYearExpectedRevenueGrowth: Double?,
        nextYearRevenueGrowth: Double?,
        grossMargin: Double?,
        netMargin: Double?,
        ttmPEGRatio: Double?,
        lastYearEPSGrowth: Double?,
        ttmVsNTMEPSGrowth: Double?,
        currentQuarterEPSGrowthVsPreviousYear: Double?,
        twoYearStackExpectedEPSGrowth: Double?,
        lastYearRevenueGrowth: Double?,
        ttmVsNTMRevenueGrowth: Double?,
        currentQuarterRevenueGrowthVsPreviousYear: Double?,
        twoYearStackExpectedRevenueGrowth: Double?,
        currentPrice: Double?,
        marketCap: Double?,
        sharesOutstanding: Double?,
        baseYear: Int?,
        yearlyProjections: [YearlyProjectionResponse]?,
        wacc: Double?,
        terminalGrowthRate: Double?,
        terminalMargin: Double?,
        exitPELow: Double?,
        exitPEHigh: Double?,
        dcfBasePrice: Double?,
        dcfBearPrice: Double?,
        dcfBullPrice: Double?,
        netDebt: Double?
    ) {
        self.symbol = symbol
        self.ttmPE = ttmPE
        self.forwardPE = forwardPE
        self.twoYearForwardPE = twoYearForwardPE
        self.ttmEPSGrowth = ttmEPSGrowth
        self.currentYearExpectedEPSGrowth = currentYearExpectedEPSGrowth
        self.nextYearEPSGrowth = nextYearEPSGrowth
        self.ttmRevenueGrowth = ttmRevenueGrowth
        self.currentYearExpectedRevenueGrowth = currentYearExpectedRevenueGrowth
        self.nextYearRevenueGrowth = nextYearRevenueGrowth
        self.grossMargin = grossMargin
        self.netMargin = netMargin
        self.ttmPEGRatio = ttmPEGRatio
        self.lastYearEPSGrowth = lastYearEPSGrowth
        self.ttmVsNTMEPSGrowth = ttmVsNTMEPSGrowth
        self.currentQuarterEPSGrowthVsPreviousYear = currentQuarterEPSGrowthVsPreviousYear
        self.twoYearStackExpectedEPSGrowth = twoYearStackExpectedEPSGrowth
        self.lastYearRevenueGrowth = lastYearRevenueGrowth
        self.ttmVsNTMRevenueGrowth = ttmVsNTMRevenueGrowth
        self.currentQuarterRevenueGrowthVsPreviousYear = currentQuarterRevenueGrowthVsPreviousYear
        self.twoYearStackExpectedRevenueGrowth = twoYearStackExpectedRevenueGrowth
        self.currentPrice = currentPrice
        self.marketCap = marketCap
        self.sharesOutstanding = sharesOutstanding
        self.baseYear = baseYear
        self.yearlyProjections = yearlyProjections
        self.wacc = wacc
        self.terminalGrowthRate = terminalGrowthRate
        self.terminalMargin = terminalMargin
        self.exitPELow = exitPELow
        self.exitPEHigh = exitPEHigh
        self.dcfBasePrice = dcfBasePrice
        self.dcfBearPrice = dcfBearPrice
        self.dcfBullPrice = dcfBullPrice
        self.netDebt = netDebt
    }
}
