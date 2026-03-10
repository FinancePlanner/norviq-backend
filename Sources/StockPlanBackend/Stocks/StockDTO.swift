import StockPlanShared
import Vapor

typealias StockRequest = StockPlanShared.StockRequest
typealias StockResponse = StockPlanShared.StockResponse

struct Cart: Content, Sendable {
    var stocks: [Stock]

    init(stocks: [Stock] = []) {
        self.stocks = stocks
    }
}

typealias WatchlistItemRequest = StockPlanShared.WatchlistItemRequest
typealias WatchlistItemResponse = StockPlanShared.WatchlistItemResponse
typealias ResearchNoteRequest = StockPlanShared.ResearchNoteRequest
typealias ResearchNoteResponse = StockPlanShared.ResearchNoteResponse
typealias PriceRange = StockPlanShared.PriceRange
typealias StockValuationRequest = StockPlanShared.StockValuationRequest
typealias StockHistory = StockPlanShared.StockHistory
typealias StockNews = StockPlanShared.StockNews
typealias BulkStockRequest = StockPlanShared.BulkStockRequest
typealias BulkStockResultItem = StockPlanShared.BulkStockResultItem
typealias BulkStockResponse = StockPlanShared.BulkStockResponse

struct TargetRequest: Codable, Content, Sendable, Equatable {
    let symbol: String
    let scenario: String
    let targetPrice: Double
    let targetDate: String?
    let rationale: String?
}

struct TargetResponse: Codable, Content, Sendable, Equatable {
    let id: String
    let symbol: String
    let scenario: String
    let targetPrice: Double
    let targetDate: String?
    let rationale: String?
}
