import Vapor

enum TickerCheck: Equatable {
    case exists
    case missing
    /// The provider could not answer (down, rate limited). Treated as valid so
    /// market-data quota never blocks publishing.
    case unknown
}

protocol ArticleTickerVerifier: Sendable {
    func check(_ symbol: String, on req: Request) async -> TickerCheck
}

struct MarketProfileTickerVerifier: ArticleTickerVerifier {
    func check(_ symbol: String, on req: Request) async -> TickerCheck {
        do {
            _ = try await req.application.marketDataService.profile(symbol: symbol, on: req)
            return .exists
        } catch let abort as any AbortError where abort.status == .notFound {
            return .missing
        } catch {
            req.logger.warning("articles.ticker_check_unavailable symbol=\(symbol) error=\(String(describing: error))")
            return .unknown
        }
    }
}

extension Application {
    private struct ArticleTickerVerifierKey: StorageKey {
        typealias Value = any ArticleTickerVerifier
    }

    var articleTickerVerifier: any ArticleTickerVerifier {
        get { storage[ArticleTickerVerifierKey.self] ?? MarketProfileTickerVerifier() }
        set { storage[ArticleTickerVerifierKey.self] = newValue }
    }
}
