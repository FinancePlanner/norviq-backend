import Vapor

struct CsvImportPreviewItem: Content, Sendable {
    let line: Int
    let symbol: String
    let shares: Double?
    let buyPrice: Double?
    let buyDate: String?
    let notes: String?
}

struct CsvImportPreviewError: Content, Sendable {
    let line: Int
    let message: String
}

struct CsvImportPreviewResponse: Content, Sendable {
    let provider: String
    let items: [CsvImportPreviewItem]
    let errors: [CsvImportPreviewError]
}

struct CsvImportCommitResponse: Content, Sendable {
    let provider: String
    let inserted: [StockResponse]
    let updated: [StockResponse]
    let errors: [CsvImportPreviewError]
}
