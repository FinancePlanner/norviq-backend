import StockPlanShared

typealias AllocationItem = StockPlanShared.AllocationItem
typealias PortfolioSummaryResponse = StockPlanShared.PortfolioSummaryResponse
typealias PerformancePoint = StockPlanShared.PerformancePoint
typealias PortfolioPerformanceResponse = StockPlanShared.PortfolioPerformanceResponse
typealias TransactionResponse = StockPlanShared.TransactionResponse
typealias LotResponse = StockPlanShared.LotResponse
typealias PnlBySymbol = StockPlanShared.PnlBySymbol
typealias PnlResponse = StockPlanShared.PnlResponse

struct PortfolioSectorHoldingContribution: Codable, Equatable, Identifiable {
    var id: String {
        symbol
    }

    let symbol: String
    let value: Double
    let weightPercent: Double
}

struct PortfolioSectorExposureItem: Codable, Equatable, Identifiable {
    var id: String {
        sector
    }

    let sector: String
    let value: Double
    let weightPercent: Double
    let benchmarkWeightPercent: Double?
    let overweightPercent: Double?
    let holdings: [PortfolioSectorHoldingContribution]
}

struct PortfolioSectorExposureResponse: Codable, Equatable {
    let baseCurrency: String
    let totalValue: Double
    let investedValue: Double
    let cashBalance: Double
    let benchmarkName: String
    let benchmarkAsOf: String
    let sectors: [PortfolioSectorExposureItem]
}
