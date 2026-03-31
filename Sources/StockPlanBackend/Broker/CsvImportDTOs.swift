import Vapor
import StockPlanShared

typealias CsvImportPreviewItem = StockPlanShared.CsvImportPreviewItem
typealias CsvImportPreviewError = StockPlanShared.CsvImportPreviewError
typealias CsvImportPreviewResponse = StockPlanShared.CsvImportPreviewResponse
typealias CsvImportCommitResponse = StockPlanShared.CsvImportCommitResponse

extension CsvImportPreviewItem: Content {}
extension CsvImportPreviewError: Content {}
extension CsvImportPreviewResponse: Content {}
extension CsvImportCommitResponse: Content {}
