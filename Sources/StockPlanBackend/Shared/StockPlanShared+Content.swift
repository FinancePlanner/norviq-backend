import StockPlanShared
import Vapor

extension StockRequest: @retroactive Content {}
extension StockResponse: @retroactive Content {}
extension WatchlistItemRequest: @retroactive Content {}
extension WatchlistItemResponse: @retroactive Content {}
extension ResearchNoteRequest: @retroactive Content {}
extension ResearchNoteResponse: @retroactive Content {}
extension PriceRange: @retroactive Content {}
extension StockValuationRequest: @retroactive Content {}
extension BulkStockRequest: @retroactive Content {}
extension BulkStockResultItem: @retroactive Content {}
extension BulkStockResponse: @retroactive Content {}

extension PortfolioSummaryResponse: @retroactive Content {}
extension PortfolioPerformanceResponse: @retroactive Content {}
extension TransactionResponse: @retroactive Content {}
extension LotResponse: @retroactive Content {}
extension PnlResponse: @retroactive Content {}

extension UserProfile: @retroactive Content {}
extension GetUserProfileRequest: @retroactive Content {}
extension GetUserProfileResponse: @retroactive Content {}
extension UpdateUserProfileRequest: @retroactive Content {}
extension UpdateUserProfileResponse: @retroactive Content {}
extension DeleteUserProfileRequest: @retroactive Content {}
extension DeleteUserProfileResponse: @retroactive Content {}
