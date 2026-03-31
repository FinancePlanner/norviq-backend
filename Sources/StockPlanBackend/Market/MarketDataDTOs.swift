import Vapor
import StockPlanShared

typealias StockDetailsResponse = StockPlanShared.StockDetailsResponse
typealias QuoteResponse = StockPlanShared.QuoteResponse
typealias CompanyProfileResponse = StockPlanShared.CompanyProfileResponse
typealias PriceBarResponse = StockPlanShared.PriceBarResponse
typealias HistoryResponse = StockPlanShared.HistoryResponse
typealias SearchResultResponse = StockPlanShared.SearchResultResponse
typealias FxRateResponse = StockPlanShared.FxRateResponse
typealias QuoteBatchResponse = StockPlanShared.QuoteBatchResponse

extension StockDetailsResponse: Content {}
extension QuoteResponse: Content {}
extension CompanyProfileResponse: Content {}
extension PriceBarResponse: Content {}
extension HistoryResponse: Content {}
extension SearchResultResponse: Content {}
extension FxRateResponse: Content {}
extension QuoteBatchResponse: Content {}
