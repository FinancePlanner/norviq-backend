import Vapor

struct StockRequest: Content {
    let symbol: String
    let shares: Double
    let buyPrice: Double
    let buyDate: String
    let notes: String?
}

struct StockResponse: Content {
    let id: String
    let symbol: String
    let shares: Double
    let buyPrice: Double
    let buyDate: String
    let notes: String?
}

struct Cart: Content, Sendable {
    var stocks: [Stock]

    init(stocks: [Stock] = []) {
        self.stocks = stocks
    }
}

struct WatchlistItemRequest: Content {
    let symbol: String
}

struct WatchlistItemResponse: Content {
    let id: String
    let symbol: String
}

struct ResearchNoteRequest: Content {
    let symbol: String
    let title: String?
    let thesis: String
    let risks: String?
    let catalysts: String?
    let referenceLinks: [String]?
}

struct ResearchNoteResponse: Content {
    let id: String
    let symbol: String
    let title: String?
    let thesis: String
    let risks: String?
    let catalysts: String?
    let referenceLinks: [String]?
}

struct TargetRequest: Content {
    let symbol: String
    let scenario: String
    let targetPrice: Double
    let targetDate: String?
    let rationale: String?
}

struct TargetResponse: Content {
    let id: String
    let symbol: String
    let scenario: String
    let targetPrice: Double
    let targetDate: String?
    let rationale: String?
}

struct StockHistory: Content {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int
}

struct StockNews: Content {
    let title: String
    let url: String
    let date: String
}
