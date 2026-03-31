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

extension TargetRequest: Content {}
extension TargetResponse: Content {}
