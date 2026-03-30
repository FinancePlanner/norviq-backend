@testable import StockPlanBackend
import VaporTesting
import Testing

@Suite("OpenAPI Docs Tests")
struct OpenAPIDocsTests {
    @Test("OpenAPI spec includes health, stock valuation, and UserProfile endpoints and schemas")
    func docsAreBundled() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)

            try await app.testing().test(.GET, "openapi.yaml", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/yaml; charset=utf-8")

                let body = res.body.string
                #expect(body.contains("/health:"))
                #expect(body.contains("operationId: health"))
                #expect(body.contains("HealthResponse:"))
                #expect(body.contains("/v1/market/details:"))
                #expect(body.contains("/v1/market/history:"))
                #expect(body.contains("/v1/market/history/archive:"))
                #expect(body.contains("/v1/market/history/archive/sync:"))
                #expect(body.contains("/v1/market/news:"))
                #expect(body.contains("/v1/market/news/archive:"))
                #expect(body.contains("/v1/market/news/archive/sync:"))
                #expect(body.contains("operationId: getMarketDetails"))
                #expect(body.contains("operationId: getMarketHistory"))
                #expect(body.contains("operationId: getArchivedMarketHistory"))
                #expect(body.contains("operationId: syncArchivedMarketHistory"))
                #expect(body.contains("operationId: getMarketNews"))
                #expect(body.contains("operationId: getArchivedMarketNews"))
                #expect(body.contains("operationId: syncArchivedMarketNews"))
                #expect(body.contains("Market data provider unavailable or misconfigured"))
                #expect(body.contains("Market news provider unavailable or misconfigured"))
                #expect(body.contains("If market data is disabled"))
                #expect(body.contains("MARKET_PROVIDER=finnhub"))
                #expect(body.contains("FINNHUB_API_KEY"))
                #expect(body.contains("FINNHUB_WEBHOOK_URL"))
                #expect(body.contains("FINNHUB_WEBHOOK_SECRET"))
                #expect(body.contains("/webhooks/finnhub/news:"))
                #expect(body.contains("operationId: finnhubNewsWebhook"))
                #expect(body.contains("X-Finnhub-Secret"))
                #expect(body.contains("StockDetailsResponse:"))
                #expect(body.contains("StockHistory:"))
                #expect(body.contains("StockNews:"))
                #expect(body.contains("operationId: finnhubQuote"))
                #expect(body.contains("operationId: finnhubSearch"))
                #expect(body.contains("operationId: finnhubCompanyNews"))
                #expect(body.contains("operationId: finnhubStockCandles"))
                #expect(body.contains("operationId: finnhubCompanyProfile2"))
                #expect(body.contains("operationId: finnhubForexRates"))
                #expect(body.contains("finnhubQueryToken:"))
                #expect(body.contains("finnhubHeaderToken:"))
                #expect(body.contains("finnhubWebhookSecretHeader:"))
                #expect(body.contains("finnhubWebhookSecretQuery:"))
                #expect(body.contains("X-Finnhub-Token"))
                #expect(body.contains("/v1/stocks/symbol/{symbol}/valuation:"))
                #expect(body.contains("operationId: getStockValuation"))
                #expect(body.contains("operationId: createStockValuation"))
                #expect(body.contains("operationId: updateStockValuation"))
                #expect(body.contains("authenticated user's stock"))
                #expect(body.contains("must already exist in the authenticated user's portfolio"))
                #expect(body.contains("PriceRange:"))
                #expect(body.contains("StockValuationRequest:"))
                #expect(body.contains("/v1/users:"))
                #expect(body.contains("/v1/users/{id}:"))
                #expect(body.contains("operationId: getUserProfile"))
                #expect(body.contains("operationId: updateUserProfile"))
                #expect(body.contains("operationId: deleteUserProfile"))
                #expect(body.contains("operationId: getUserProfileByID"))
                #expect(body.contains("operationId: updateUserProfileByID"))
                #expect(body.contains("operationId: deleteUserProfileByID"))
                #expect(body.contains("UserProfile:"))
                #expect(body.contains("UpdateUserProfileRequest:"))
                #expect(body.contains("DeleteUserProfileResponse:"))
            })
        } catch {
            try await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }
}
