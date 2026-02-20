import Vapor
import StockPlanShared

extension AuthRegisterRequest: @retroactive Content {}
extension AuthLoginRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension AuthUserResponse: @retroactive Content {}
extension AuthForgotPasswordRequest: @retroactive Content {}
extension AuthForgotPasswordResponse: @retroactive Content {}
extension AuthResetPasswordRequest: @retroactive Content {}
extension AuthRefreshRequest: @retroactive Content {}

extension StockRequest: @retroactive Content {}
extension StockResponse: @retroactive Content {}
extension WatchlistItemRequest: @retroactive Content {}
extension WatchlistItemResponse: @retroactive Content {}
extension ResearchNoteRequest: @retroactive Content {}
extension ResearchNoteResponse: @retroactive Content {}
extension TargetRequest: @retroactive Content {}
extension TargetResponse: @retroactive Content {}

extension PortfolioSummaryResponse: @retroactive Content {}
extension PortfolioPerformanceResponse: @retroactive Content {}
extension TransactionResponse: @retroactive Content {}
extension LotResponse: @retroactive Content {}
extension PnlResponse: @retroactive Content {}
