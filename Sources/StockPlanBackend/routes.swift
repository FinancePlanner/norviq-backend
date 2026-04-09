import Fluent
import Vapor
import Foundation

private struct HealthResponse: Content {
    let status: String
}

func routes(_ app: Application) throws {
    let api = app.grouped("v1")

    app.get("health") { _ async -> HealthResponse in
        HealthResponse(status: "ok")
    }

    api.get { req async in
        "It works!"
    }

    api.get("hello") { req async -> String in
        "Hello, world!"
    }

    try registerOpenAPIDocsRoutes(app)
    try app.register(collection: FinnhubWebhookController())

    try api.register(collection: AuthController())
    try api.register(collection: StockController())
    try api.register(collection: MarketDataController())
    try api.register(collection: PortfolioController())
    try api.register(collection: BrokerController())
    try api.register(collection: StatisticsController())
    try api.register(collection: NewsController())
    try api.register(collection: DashboardController())
    try api.register(collection: UserProfileController())
    try api.register(collection: EarningsController())
    try api.register(collection: FeedbackController())
    try api.register(collection: CryptoController())
    try api.register(collection: BudgetController())
    try api.register(collection: ExpensesController())
    try api.register(collection: ReportsController())
    try api.register(collection: GoalsController())
    try api.register(collection: UserActivityController())
    try api.register(collection: BadgeController())
    try api.register(collection: AssetsController())
}

private func registerOpenAPIDocsRoutes(_ app: Application) throws {
    app.get("openapi.yaml") { _ async throws -> Response in
        guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml") else {
            throw Abort(.notFound, reason: "openapi.yaml is not bundled (check Package.swift resources)")
        }

        let data = try Data(contentsOf: url)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/yaml; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    app.get("docs") { _ async throws -> Response in
        let html = """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>StockPlanBackend API Docs</title>
            <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
          </head>
          <body>
            <div id="swagger-ui"></div>
            <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
            <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js"></script>
            <script>
              window.onload = () => {
                window.ui = SwaggerUIBundle({
                  url: '/openapi.yaml',
                  dom_id: '#swagger-ui',
                  presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
                  layout: 'BaseLayout'
                });
              };
            </script>
          </body>
        </html>
        """

        let res = Response(status: .ok)
        res.headers.contentType = .html
        res.body = .init(string: html)
        return res
    }
}
