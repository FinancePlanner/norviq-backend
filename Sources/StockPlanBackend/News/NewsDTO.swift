import Vapor

struct NewsItemRequest: Content {
    let symbol: String
    let headline: String
    let source: String?
    let url: String?
    let summary: String?
    let publishedAt: String?
}

struct NewsItemResponse: Content {
    let id: String
    let symbol: String
    let headline: String
    let source: String?
    let url: String?
    let summary: String?
    let publishedAt: String
    let createdAt: String?
    let updatedAt: String?
}

struct NewsSyncResponse: Content {
    let provider: String
    let symbolsCount: Int
    let fetchedCount: Int
    let insertedCount: Int
    let updatedCount: Int
    let skippedCount: Int
}
