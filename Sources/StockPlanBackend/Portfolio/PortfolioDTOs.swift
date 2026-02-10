import Vapor

struct AllocationItem: Content {
    let symbol: String
    let value: Double
    let currency: String
}

struct PortfolioSummaryResponse: Content {
    let baseCurrency: String
    let totalValue: Double
    let totalCost: Double
    let unrealizedPnl: Double
    let realizedPnl: Double
    let allocation: [AllocationItem]
}

struct PerformancePoint: Content {
    let date: String
    let value: Double
}

struct PortfolioPerformanceResponse: Content {
    let baseCurrency: String
    let points: [PerformancePoint]
}

struct TransactionResponse: Content {
    let id: String
    let accountId: String
    let instrumentId: String
    let type: String
    let quantity: Double?
    let price: Double?
    let currency: String
    let tradeDate: String
    let settleDate: String?
    let fees: Double?
}

struct LotResponse: Content {
    let id: String
    let accountId: String
    let instrumentId: String
    let openDate: String
    let closeDate: String?
    let openQuantity: Double
    let remainingQuantity: Double
    let openPrice: Double
    let currency: String
    let realizedPnl: Double?
    let status: String
}

struct PnlBySymbol: Content {
    let symbol: String
    let currency: String
    let realizedPnl: Double
    let unrealizedPnl: Double
}

struct PnlResponse: Content {
    let baseCurrency: String
    let items: [PnlBySymbol]
}
