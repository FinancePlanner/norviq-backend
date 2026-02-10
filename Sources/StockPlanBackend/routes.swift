import Fluent
import Vapor
import Foundation

func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    try registerOpenAPIDocsRoutes(app)

    try app.register(collection: AuthController())
    try app.register(collection: StockController())
    try app.register(collection: MarketDataController())
    try app.register(collection: PortfolioController())
    try app.register(collection: BrokerController())
    try app.register(collection: TodoController())
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
