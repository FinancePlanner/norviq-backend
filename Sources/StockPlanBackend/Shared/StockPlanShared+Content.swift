import StockPlanShared
import Vapor

// MARK: - Common

extension APISuccess: @retroactive Content, @unchecked Sendable {}
extension APIMessageResponse: @retroactive Content, @unchecked Sendable {}
extension APIErrorResponse: @retroactive Content, @unchecked Sendable {}
extension APIEnvelope: @retroactive Content, @unchecked Sendable {}
extension EmptyAPIResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Auth

extension AuthLoginRequest: @retroactive Content, @unchecked Sendable {}
extension AuthResponse: @retroactive Content, @unchecked Sendable {}
extension AuthUserResponse: @retroactive Content, @unchecked Sendable {}
extension AuthForgotPasswordRequest: @retroactive Content, @unchecked Sendable {}
extension AuthForgotPasswordResponse: @retroactive Content, @unchecked Sendable {}
extension AuthResetPasswordRequest: @retroactive Content, @unchecked Sendable {}
extension AuthRefreshRequest: @retroactive Content, @unchecked Sendable {}
extension OAuthStartRequest: Content, @unchecked Sendable {}
extension OAuthStartResponse: Content, @unchecked Sendable {}
extension OAuthExchangeRequest: Content, @unchecked Sendable {}

// MARK: - Stocks

extension StockRequest: @retroactive Content, @unchecked Sendable {}
extension SellStockRequest: @retroactive Content, @unchecked Sendable {}
extension StockResponse: @retroactive Content, @unchecked Sendable {}
extension PortfolioListRequest: @retroactive Content, @unchecked Sendable {}
extension PortfolioListResponse: @retroactive Content, @unchecked Sendable {}
extension WatchlistItemRequest: @retroactive Content, @unchecked Sendable {}
extension WatchlistItemUpdateRequest: @retroactive Content, @unchecked Sendable {}
extension WatchlistItemResponse: @retroactive Content, @unchecked Sendable {}
extension WatchlistListRequest: @retroactive Content, @unchecked Sendable {}
extension WatchlistListResponse: @retroactive Content, @unchecked Sendable {}
extension WatchlistStatus: @retroactive Content, @unchecked Sendable {}
extension ResearchNoteRequest: @retroactive Content, @unchecked Sendable {}
extension ResearchNoteResponse: @retroactive Content, @unchecked Sendable {}
extension PriceRange: @retroactive Content, @unchecked Sendable {}
extension StockValuationRequest: @retroactive Content, @unchecked Sendable {}
extension StockValuationDraft: @retroactive Content, @unchecked Sendable {}
extension StockHistory: @retroactive Content, @unchecked Sendable {}
extension StockNews: @retroactive Content, @unchecked Sendable {}
extension BulkStockRequest: @retroactive Content, @unchecked Sendable {}
extension BulkStockResultItem: @retroactive Content, @unchecked Sendable {}
extension BulkStockResponse: @retroactive Content, @unchecked Sendable {}
extension TargetRequest: @retroactive Content, @unchecked Sendable {}
extension TargetResponse: @retroactive Content, @unchecked Sendable {}

// Price Chart
extension PriceChartPoint: @retroactive Content, @unchecked Sendable {}
extension PriceChartSeries: @retroactive Content, @unchecked Sendable {}
extension PriceChartComparisonResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Dashboard

extension DashboardResponse: @retroactive Content, @unchecked Sendable {}
extension DashboardPerformerDTO: @retroactive Content, @unchecked Sendable {}
extension DashboardAllocationDTO: @retroactive Content, @unchecked Sendable {}

// MARK: - Portfolio

extension PortfolioSummaryResponse: @retroactive Content, @unchecked Sendable {}
extension PortfolioPerformanceResponse: @retroactive Content, @unchecked Sendable {}
extension TransactionResponse: @retroactive Content, @unchecked Sendable {}
extension LotResponse: @retroactive Content, @unchecked Sendable {}
extension PnlResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - User Profile

extension GetUserProfileRequest: @retroactive Content, @unchecked Sendable {}
extension GetUserProfileResponse: @retroactive Content, @unchecked Sendable {}
extension UpdateUserProfileRequest: @retroactive Content, @unchecked Sendable {}
extension UpdateUserProfileResponse: @retroactive Content, @unchecked Sendable {}
extension UpdateUsernameRequest: @retroactive Content, @unchecked Sendable {}
extension UpdateEmailRequest: @retroactive Content, @unchecked Sendable {}
extension UpdatePasswordRequest: @retroactive Content, @unchecked Sendable {}
extension DeleteUserProfileRequest: @retroactive Content, @unchecked Sendable {}
extension DeleteUserProfileResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - News & Earnings

extension NewsItemResponse: @retroactive Content, @unchecked Sendable {}
extension NewsSyncResponse: @retroactive Content, @unchecked Sendable {}
extension FinnhubNewsWebhookResponse: @retroactive Content, @unchecked Sendable {}
extension EarningsItemResponse: @retroactive Content, @unchecked Sendable {}
extension EarningsQueryRequest: @retroactive Content, @unchecked Sendable {}

// MARK: - Broker / CSV

extension CsvImportPreviewItem: @retroactive Content, @unchecked Sendable {}
extension CsvImportPreviewError: @retroactive Content, @unchecked Sendable {}
extension CsvImportPreviewResponse: @retroactive Content, @unchecked Sendable {}
extension CsvImportCommitResponse: @retroactive Content, @unchecked Sendable {}
extension BrokerConnectionResponse: @retroactive Content, @unchecked Sendable {}
extension BrokerHoldingResponse: @retroactive Content, @unchecked Sendable {}
extension BrokerSyncResponse: @retroactive Content, @unchecked Sendable {}
extension BrokerConnectStartRequest: @retroactive Content, @unchecked Sendable {}
extension BrokerConnectStartResponse: @retroactive Content, @unchecked Sendable {}
extension BrokerSyncStatusResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Statistics

extension StatisticsDTO: @retroactive Content, @unchecked Sendable {}
extension ImportedStocksStatisticsDTO: @retroactive Content, @unchecked Sendable {}
extension StockStatisticsSummaryDTO: @retroactive Content, @unchecked Sendable {}
extension StockAllocationDTO: @retroactive Content, @unchecked Sendable {}
extension SectorAllocationDTO: @retroactive Content, @unchecked Sendable {}
extension CalendarPerformanceDTO: @retroactive Content, @unchecked Sendable {}
extension WatchlistStatisticsDTO: @retroactive Content, @unchecked Sendable {}
extension WatchlistSymbolDTO: @retroactive Content, @unchecked Sendable {}
extension LooklistStatisticsDTO: @retroactive Content, @unchecked Sendable {}
extension LooklistConvictionDTO: @retroactive Content, @unchecked Sendable {}
extension MarketStatisticsDTO: @retroactive Content, @unchecked Sendable {}
extension MarketHeatmapDTO: @retroactive Content, @unchecked Sendable {}

// MARK: - Crypto

extension CryptoAssetResponse: @retroactive Content, @unchecked Sendable {}
extension CryptoQuoteResponse: @retroactive Content, @unchecked Sendable {}
extension CryptoQuoteShortResponse: @retroactive Content, @unchecked Sendable {}
extension CryptoHistoricalLightPoint: @retroactive Content, @unchecked Sendable {}
extension CryptoHistoricalFullPoint: @retroactive Content, @unchecked Sendable {}
extension CryptoHistoricalPoint: @retroactive Content, @unchecked Sendable {}
extension CryptoPortfolioItemRequest: @retroactive Content, @unchecked Sendable {}
extension CryptoPortfolioItemResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Expenses

extension BudgetSnapshotRequest: @retroactive Content, @unchecked Sendable {}
extension BudgetSnapshotResponse: @retroactive Content, @unchecked Sendable {}
extension HouseholdPartnerProfileRequest: @retroactive Content, @unchecked Sendable {}
extension HouseholdPartnerProfileResponse: @retroactive Content, @unchecked Sendable {}
extension BudgetPlanItemRequest: @retroactive Content, @unchecked Sendable {}
extension BudgetPlanItemResponse: @retroactive Content, @unchecked Sendable {}
extension ExpenseRequest: @retroactive Content, @unchecked Sendable {}
extension ExpenseResponse: @retroactive Content, @unchecked Sendable {}
extension PillarPlanningSummaryResponse: @retroactive Content, @unchecked Sendable {}
extension BudgetMonthSummaryResponse: @retroactive Content, @unchecked Sendable {}
extension BudgetYearSummaryResponse: @retroactive Content, @unchecked Sendable {}
extension ReportsCashFlowPointResponse: @retroactive Content, @unchecked Sendable {}
extension ExpenseCategoryResponse: @retroactive Content, @unchecked Sendable {}
extension RecurringTemplateResponse: @retroactive Content, @unchecked Sendable {}
extension ReportsOverviewResponse: @retroactive Content, @unchecked Sendable {}
extension ReportSuggestionSeverity: @retroactive Content, @unchecked Sendable {}
extension ReportSuggestionCategory: @retroactive Content, @unchecked Sendable {}
extension ReportSuggestionResponse: @retroactive Content, @unchecked Sendable {}
extension ReportSuggestionsResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Goals & Dashboard Insights

extension GoalRequest: @retroactive Content, @unchecked Sendable {}
extension GoalStatus: @retroactive Content, @unchecked Sendable {}
extension GoalStatusSource: @retroactive Content, @unchecked Sendable {}
extension GoalStatusUpdateRequest: @retroactive Content, @unchecked Sendable {}
extension GoalResponse: @retroactive Content, @unchecked Sendable {}
extension DashboardInsightsResponse: @retroactive Content, @unchecked Sendable {}
extension DashboardFinancialHealthDTO: @retroactive Content, @unchecked Sendable {}
extension FinancialHealthStatus: @retroactive Content, @unchecked Sendable {}

// MARK: - Activity

extension UserActivityResponse: @retroactive Content, @unchecked Sendable {}

// MARK: - Market (FinanceShared types used as Vapor responses)

extension StockDetailsResponse: @retroactive Content, @unchecked Sendable {}
extension QuoteResponse: @retroactive Content, @unchecked Sendable {}
extension CompanyProfileResponse: @retroactive Content, @unchecked Sendable {}
extension PriceBarResponse: @retroactive Content, @unchecked Sendable {}
extension HistoryResponse: @retroactive Content, @unchecked Sendable {}
extension SearchResultResponse: @retroactive Content, @unchecked Sendable {}
extension FxRateResponse: @retroactive Content, @unchecked Sendable {}
extension QuoteBatchResponse: @retroactive Content, @unchecked Sendable {}
extension BasicFinancialSeriesPoint: @retroactive Content, @unchecked Sendable {}
extension BasicFinancialsResponse: @retroactive Content, @unchecked Sendable {}
extension RatiosTTMResponse: @retroactive Content, @unchecked Sendable {}
extension BalanceSheetStatementResponse: @retroactive Content, @unchecked Sendable {}
extension CashFlowStatementResponse: @retroactive Content, @unchecked Sendable {}
extension FinancialGrowthResponse: @retroactive Content, @unchecked Sendable {}
extension AnalystEstimatesResponse: @retroactive Content, @unchecked Sendable {}
extension RatiosResponse: @retroactive Content, @unchecked Sendable {}
