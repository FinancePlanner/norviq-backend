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

struct FinnhubNewsWebhookRequest: Content {
    let news: [FinnhubNewsWebhookItem]

    init(news: [FinnhubNewsWebhookItem]) {
        self.news = news
    }

    init(from decoder: any Decoder) throws {
        if let items = try? [FinnhubNewsWebhookItem](from: decoder) {
            self.news = items
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.news =
            (try? container.decode([FinnhubNewsWebhookItem].self, forKey: .news))
            ?? (try? container.decode([FinnhubNewsWebhookItem].self, forKey: .data))
            ?? (try? container.decode([FinnhubNewsWebhookItem].self, forKey: .articles))
            ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case news
        case data
        case articles
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: EncodeKeys.self)
        try container.encode(news, forKey: .news)
    }

    private enum EncodeKeys: String, CodingKey {
        case news
    }
}

struct FinnhubNewsWebhookItem: Content {
    let category: String?
    let datetime: Double?
    let headline: String?
    let id: Int?
    let image: String?
    let related: String?
    let source: String?
    let summary: String?
    let symbol: String?
    let symbols: [String]?
    let publishedAt: String?
    let url: String?
}

struct FinnhubNewsWebhookResponse: Content {
    let provider: String
    let receivedCount: Int
    let matchedSymbolsCount: Int
    let matchedUsersCount: Int
    let insertedCount: Int
    let skippedCount: Int
}
