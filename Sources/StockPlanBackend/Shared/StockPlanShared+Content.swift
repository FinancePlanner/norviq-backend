import StockPlanShared
import Vapor

extension StockRequest: @retroactive Content {}
extension StockResponse: @retroactive Content {}
extension WatchlistItemRequest: @retroactive Content {}
extension WatchlistItemResponse: @retroactive Content {}
extension ResearchNoteRequest: @retroactive Content {}
extension ResearchNoteResponse: @retroactive Content {}
extension TargetRequest: @retroactive Content {}
extension TargetResponse: @retroactive Content {}
extension BulkStockRequest: @retroactive Content {}
extension BulkStockResultItem: @retroactive Content {}
extension BulkStockResponse: @retroactive Content {}

extension PortfolioSummaryResponse: @retroactive Content {}
extension PortfolioPerformanceResponse: @retroactive Content {}
extension TransactionResponse: @retroactive Content {}
extension LotResponse: @retroactive Content {}
extension PnlResponse: @retroactive Content {}
