import StockPlanShared
import Vapor

typealias NewsItemRequest = StockPlanShared.NewsItemRequest
typealias NewsItemResponse = StockPlanShared.NewsItemResponse
typealias NewsSyncResponse = StockPlanShared.NewsSyncResponse
typealias FinnhubNewsWebhookResponse = StockPlanShared.FinnhubNewsWebhookResponse

extension NewsItemRequest: Content {}
extension NewsItemResponse: Content {}
extension NewsSyncResponse: Content {}
extension FinnhubNewsWebhookResponse: Content {}

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
