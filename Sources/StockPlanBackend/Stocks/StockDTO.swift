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
typealias TargetRequest = StockPlanShared.TargetRequest
typealias TargetResponse = StockPlanShared.TargetResponse
typealias StockHistory = StockPlanShared.StockHistory
typealias StockNews = StockPlanShared.StockNews
typealias BulkStockRequest = StockPlanShared.BulkStockRequest
typealias BulkStockResultItem = StockPlanShared.BulkStockResultItem
typealias BulkStockResponse = StockPlanShared.BulkStockResponse
