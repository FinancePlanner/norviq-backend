import StockPlanShared
import Vapor

typealias StockRequest = StockPlanShared.StockRequest
typealias StockResponse = StockPlanShared.StockResponse
typealias PortfolioListRequest = StockPlanShared.PortfolioListRequest
typealias PortfolioListResponse = StockPlanShared.PortfolioListResponse
typealias WatchlistListRequest = StockPlanShared.WatchlistListRequest
typealias WatchlistListResponse = StockPlanShared.WatchlistListResponse

struct Cart: Content {
    var stocks: [Stock]

    init(stocks: [Stock] = []) {
        self.stocks = stocks
    }
}

typealias WatchlistItemRequest = StockPlanShared.WatchlistItemRequest
typealias WatchlistItemUpdateRequest = StockPlanShared.WatchlistItemUpdateRequest
typealias WatchlistItemResponse = StockPlanShared.WatchlistItemResponse
typealias WatchlistStatus = StockPlanShared.WatchlistStatus
typealias ResearchNoteRequest = StockPlanShared.ResearchNoteRequest
typealias ResearchNoteResponse = StockPlanShared.ResearchNoteResponse
typealias PriceRange = StockPlanShared.PriceRange
typealias StockValuationRequest = StockPlanShared.StockValuationRequest
typealias StockHistory = StockPlanShared.StockHistory
typealias StockNews = StockPlanShared.StockNews
typealias BulkStockRequest = StockPlanShared.BulkStockRequest
typealias BulkStockResultItem = StockPlanShared.BulkStockResultItem
typealias BulkStockResponse = StockPlanShared.BulkStockResponse
typealias TargetRequest = StockPlanShared.TargetRequest
typealias TargetResponse = StockPlanShared.TargetResponse
typealias SellStockRequest = StockPlanShared.SellStockRequest

struct StockInsightsResponse: Content, Equatable {
    let generatedAt: String
    let symbol: String
    let profile: StockInsightProfileDTO
    let peers: [StockInsightPeerDTO]
    let projectionScenarios: [StockInsightProjectionScenarioDTO]
}

struct StockInsightProfileDTO: Content, Equatable {
    let symbol: String
    let companyName: String
    let currentPrice: Double
    let marketCap: Double
    let sharesOutstanding: Double
    let metrics: [String: Double]
    let dcfBasePrice: Double?
    let dcfBearPrice: Double?
    let dcfBullPrice: Double?
}

struct StockInsightPeerDTO: Content, Equatable {
    let symbol: String
    let companyName: String
    let currentPrice: Double
    let marketCap: Double
    let sharesOutstanding: Double
}

struct StockInsightProjectionScenarioDTO: Content, Equatable {
    let kind: String
    let years: [StockInsightProjectionYearDTO]
}

struct StockInsightProjectionYearDTO: Content, Equatable {
    let year: Int
    let revenue: Double
    let revenueGrowth: Double
    let netIncome: Double
    let netIncomeGrowth: Double
    let netMargin: Double
    let eps: Double
    let peLowEstimate: Double
    let peHighEstimate: Double
    let sharePriceLow: Double
    let sharePriceHigh: Double
    let cagrLow: Double?
    let cagrHigh: Double?
}

struct StockListItem: Content {
    let id: String
    let symbol: String
    let shares: Double
    let buyPrice: Double
    let buyDate: String
    let notes: String?
    let category: AssetCategory
    let portfolioListId: String?

    init(from response: StockResponse) {
        id = response.id
        symbol = response.symbol
        shares = response.shares
        buyPrice = response.buyPrice
        buyDate = response.buyDate
        notes = response.notes
        category = response.category
        portfolioListId = response.portfolioListId
    }
}
