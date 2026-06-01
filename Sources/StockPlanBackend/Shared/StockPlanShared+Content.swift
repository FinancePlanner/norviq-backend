import StockPlanShared
import Vapor

// MARK: - Common

extension APISuccess: @retroactive Content {}
extension APIMessageResponse: @retroactive Content {}
extension APIErrorResponse: @retroactive Content {}
extension APIEnvelope: @retroactive Content {}
extension EmptyAPIResponse: @retroactive Content {}

// MARK: - Auth

extension AuthLoginRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension AuthUserResponse: @retroactive Content {}
extension AuthForgotPasswordRequest: @retroactive Content {}
extension AuthForgotPasswordResponse: @retroactive Content {}
extension AuthResetPasswordRequest: @retroactive Content {}
extension AuthRefreshRequest: @retroactive Content {}

// MARK: - Stocks

extension StockRequest: @retroactive Content {}
extension SellStockRequest: @retroactive Content {}
extension StockResponse: @retroactive Content {}
extension PortfolioListRequest: @retroactive Content {}
extension PortfolioListResponse: @retroactive Content {}
extension WatchlistItemRequest: @retroactive Content {}
extension WatchlistItemUpdateRequest: @retroactive Content {}
extension WatchlistItemResponse: @retroactive Content {}
extension WatchlistListRequest: @retroactive Content {}
extension WatchlistListResponse: @retroactive Content {}
extension WatchlistStatus: @retroactive Content {}
extension ResearchNoteRequest: @retroactive Content {}
extension ResearchNoteResponse: @retroactive Content {}
extension PriceRange: @retroactive Content {}
extension StockValuationRequest: @retroactive Content {}
extension StockValuationDraft: @retroactive Content {}
extension StockHistory: @retroactive Content {}
extension StockNews: @retroactive Content {}
extension BulkStockRequest: @retroactive Content {}
extension BulkStockResultItem: @retroactive Content {}
extension BulkStockResponse: @retroactive Content {}
extension TargetRequest: @retroactive Content {}
extension TargetResponse: @retroactive Content {}

// Price Chart
extension PriceChartPoint: @retroactive Content {}
extension PriceChartSeries: @retroactive Content {}
extension PriceChartComparisonResponse: @retroactive Content {}

// MARK: - Dashboard

extension DashboardResponse: @retroactive Content {}
extension DashboardPerformerDTO: @retroactive Content {}
extension DashboardAllocationDTO: @retroactive Content {}

// MARK: - Portfolio

extension PortfolioSummaryResponse: @retroactive Content {}
extension PortfolioPerformanceResponse: @retroactive Content {}
extension PortfolioSectorHoldingContribution: Content {}
extension PortfolioSectorExposureItem: Content {}
extension PortfolioSectorExposureResponse: Content {}
extension TransactionResponse: @retroactive Content {}
extension LotResponse: @retroactive Content {}
extension PnlResponse: @retroactive Content {}

// MARK: - User Profile

extension GetUserProfileRequest: @retroactive Content {}
extension GetUserProfileResponse: @retroactive Content {}
extension UpdateUserProfileRequest: @retroactive Content {}
extension UpdateUserProfileResponse: @retroactive Content {}
extension UpdateUsernameRequest: @retroactive Content {}
extension UpdateEmailRequest: @retroactive Content {}
extension UpdatePasswordRequest: @retroactive Content {}
extension DeleteUserProfileRequest: @retroactive Content {}
extension DeleteUserProfileResponse: @retroactive Content {}

// MARK: - News & Earnings

extension NewsItemResponse: @retroactive Content {}
extension NewsSyncResponse: @retroactive Content {}
extension FinnhubNewsWebhookResponse: @retroactive Content {}
extension EarningsItemResponse: @retroactive Content {}
extension EarningsQueryRequest: @retroactive Content {}

// MARK: - Broker / CSV

extension CsvImportPreviewItem: @retroactive Content {}
extension CsvImportPreviewError: @retroactive Content {}
extension CsvImportPreviewResponse: @retroactive Content {}
extension CsvImportCommitResponse: @retroactive Content {}
extension BrokerConnectionResponse: @retroactive Content {}
extension BrokerHoldingResponse: @retroactive Content {}
extension BrokerSyncResponse: @retroactive Content {}
extension BrokerConnectStartRequest: @retroactive Content {}
extension BrokerConnectStartResponse: @retroactive Content {}
extension BrokerSyncStatusResponse: @retroactive Content {}

// MARK: - Statistics

extension StatisticsDTO: @retroactive Content {}
extension ImportedStocksStatisticsDTO: @retroactive Content {}
extension StockStatisticsSummaryDTO: @retroactive Content {}
extension StockAllocationDTO: @retroactive Content {}
extension SectorAllocationDTO: @retroactive Content {}
extension CalendarPerformanceDTO: @retroactive Content {}
extension WatchlistStatisticsDTO: @retroactive Content {}
extension WatchlistSymbolDTO: @retroactive Content {}
extension LooklistStatisticsDTO: @retroactive Content {}
extension LooklistConvictionDTO: @retroactive Content {}
extension MarketStatisticsDTO: @retroactive Content {}
extension MarketHeatmapDTO: @retroactive Content {}

// MARK: - Crypto

extension CryptoAssetResponse: @retroactive Content {}
extension CryptoQuoteResponse: @retroactive Content {}
extension CryptoQuoteShortResponse: @retroactive Content {}
extension CryptoHistoricalLightPoint: @retroactive Content {}
extension CryptoHistoricalFullPoint: @retroactive Content {}
extension CryptoHistoricalPoint: @retroactive Content {}
extension CryptoPortfolioItemRequest: @retroactive Content {}
extension CryptoPortfolioItemResponse: @retroactive Content {}
extension CryptoWatchlistItemRequest: @retroactive Content {}
extension CryptoWatchlistItemResponse: @retroactive Content {}

// MARK: - Expenses

extension BudgetSnapshotRequest: @retroactive Content {}
extension BudgetSnapshotResponse: @retroactive Content {}
extension HouseholdPartnerProfileRequest: @retroactive Content {}
extension HouseholdPartnerProfileResponse: @retroactive Content {}
extension BudgetPlanItemRequest: @retroactive Content {}
extension BudgetPlanItemResponse: @retroactive Content {}
extension ExpenseRequest: @retroactive Content {}
extension ExpenseResponse: @retroactive Content {}
extension PillarPlanningSummaryResponse: @retroactive Content {}
extension BudgetMonthSummaryResponse: @retroactive Content {}
extension BudgetYearSummaryResponse: @retroactive Content {}
extension ReportsCashFlowPointResponse: @retroactive Content {}
extension ExpenseCategoryResponse: @retroactive Content {}
extension RecurringTemplateResponse: @retroactive Content {}
extension ReportsOverviewResponse: @retroactive Content {}
extension ReportSuggestionSeverity: @retroactive Content {}
extension ReportSuggestionCategory: @retroactive Content {}
extension ReportSuggestionResponse: @retroactive Content {}
extension ReportSuggestionsResponse: @retroactive Content {}

// MARK: - Goals & Dashboard Insights

extension GoalRequest: @retroactive Content {}
extension GoalStatus: @retroactive Content {}
extension GoalStatusSource: @retroactive Content {}
extension GoalStatusUpdateRequest: @retroactive Content {}
extension GoalResponse: @retroactive Content {}
extension DashboardInsightsResponse: @retroactive Content {}
extension DashboardFinancialHealthDTO: @retroactive Content {}
extension FinancialHealthStatus: @retroactive Content {}

// MARK: - Activity

extension UserActivityResponse: @retroactive Content {}

// MARK: - Market (FinanceShared types used as Vapor responses)

extension StockDetailsResponse: @retroactive Content {}
extension QuoteResponse: @retroactive Content {}
extension CompanyProfileResponse: @retroactive Content {}
extension PriceBarResponse: @retroactive Content {}
extension HistoryResponse: @retroactive Content {}
extension SearchResultResponse: @retroactive Content {}
extension FxRateResponse: @retroactive Content {}
extension QuoteBatchResponse: @retroactive Content {}
extension BasicFinancialSeriesPoint: @retroactive Content {}
extension BasicFinancialsResponse: @retroactive Content {}
extension RatiosTTMResponse: @retroactive Content {}
extension BalanceSheetStatementResponse: @retroactive Content {}
extension CashFlowStatementResponse: @retroactive Content {}
extension FinancialGrowthResponse: @retroactive Content {}
extension AnalystEstimatesResponse: @retroactive Content {}
extension RatiosResponse: @retroactive Content {}
