import Fluent
import FluentSQL
import Foundation
import Redis
import RediStack
import Vapor

private struct HealthResponse: Content {
    let status: String
}

private struct HealthCheckResponse: Content {
    let status: String
    let checks: [String: HealthCheck]
    let version: String
    let environment: String
}

private struct HealthCheck: Content {
    let status: String
    let message: String?
    let latencyMs: Double?
}

func routes(_ app: Application) throws {
    let api = app.grouped("v1")

    app.get("health") { _ async -> HealthResponse in
        HealthResponse(status: "ok")
    }

    app.get("health", "live") { _ async -> HealthResponse in
        HealthResponse(status: "ok")
    }

    app.get("health", "ready") { req async -> Response in
        let readiness = await makeReadinessResponse(req)
        let response = Response(status: readiness.status == "not_ready" ? .serviceUnavailable : .ok)
        try? response.content.encode(readiness)
        return response
    }

    api.get { _ async in
        "It works!"
    }

    api.get("hello") { _ async -> String in
        "Hello, world!"
    }

    try registerOpenAPIDocsRoutes(app)
    try app.register(collection: FinnhubWebhookController())
    try app.register(collection: RevenueCatWebhookController())

    try api.register(collection: AuthController(environment: app.environment))
    try api.register(collection: BillingController())
    try api.register(collection: StockController())
    // Rate limit market data endpoints (quotes, search) to protect third-party API quotas.
    let marketRateLimit = RateLimitMiddleware(limit: 100, interval: 60, keyPrefix: "ratelimit:market")
    try api.grouped(marketRateLimit).register(collection: MarketDataController())
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
    try api.register(collection: PushNotificationsController())
    try api.register(collection: DataExportController(exportService: app.dataExportService))
    try api.register(collection: ExportFileController(exportService: app.dataExportService))
}

private func makeReadinessResponse(_ req: Request) async -> HealthCheckResponse {
    var checks: [String: HealthCheck] = [:]
    checks["database"] = await databaseHealthCheck(req)
    checks["redis"] = await redisHealthCheck(req)
    checks["mailer"] = mailerHealthCheck(req)
    checks["apns"] = apnsHealthCheck(req)
    checks["marketData"] = marketDataHealthCheck(req)

    let hasFailure = checks.values.contains { $0.status == "unhealthy" }
    let hasWarning = checks.values.contains { $0.status == "degraded" }
    let status = hasFailure ? "not_ready" : (hasWarning ? "degraded" : "ready")

    return HealthCheckResponse(
        status: status,
        checks: checks,
        version: Environment.get("APP_VERSION") ?? Environment.get("GIT_SHA") ?? "unknown",
        environment: req.application.environment.name
    )
}

private func databaseHealthCheck(_ req: Request) async -> HealthCheck {
    let start = DispatchTime.now()
    guard let sql = req.db(.psql) as? any SQLDatabase else {
        return HealthCheck(status: "unhealthy", message: "PostgreSQL database is not configured.", latencyMs: nil)
    }
    do {
        try await sql.raw("SELECT 1").run()
        return HealthCheck(status: "healthy", message: nil, latencyMs: elapsedMilliseconds(since: start))
    } catch {
        req.logger.error("health.ready database failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(
            status: "unhealthy",
            message: "Database check failed.",
            latencyMs: elapsedMilliseconds(since: start)
        )
    }
}

private func redisHealthCheck(_ req: Request) async -> HealthCheck {
    let start = DispatchTime.now()
    guard req.application.redis.configuration != nil else {
        return HealthCheck(status: "skipped", message: "REDIS_URL is not configured.", latencyMs: nil)
    }
    do {
        _ = try await req.application.redis.send(command: "PING", with: [])
        return HealthCheck(status: "healthy", message: nil, latencyMs: elapsedMilliseconds(since: start))
    } catch {
        req.logger.error("health.ready redis failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(
            status: "unhealthy",
            message: "Redis check failed.",
            latencyMs: elapsedMilliseconds(since: start)
        )
    }
}

private func mailerHealthCheck(_ req: Request) -> HealthCheck {
    let mfaEnabled = envBoolForHealth("AUTH_MFA_ENABLED", default: req.application.environment == .production)
    let hasResend = !(Environment.get("RESEND_API_KEY") ?? "").isEmpty
        && !(Environment.get("RESEND_FROM_EMAIL") ?? "").isEmpty
    if mfaEnabled, !hasResend {
        return HealthCheck(status: "unhealthy", message: "MFA is enabled but Resend is not configured.", latencyMs: nil)
    }
    return HealthCheck(status: hasResend ? "healthy" : "skipped", message: hasResend ? nil : "Email delivery is disabled.", latencyMs: nil)
}

private func apnsHealthCheck(_ req: Request) -> HealthCheck {
    if req.application.pushNotificationSender is NoopPushNotificationSender {
        return HealthCheck(status: "skipped", message: "APNS is disabled; push delivery is unavailable.", latencyMs: nil)
    }

    guard let config = APNSBootstrapConfiguration.fromEnvironment(app: req.application) else {
        return HealthCheck(status: "skipped", message: "APNS is not configured; push delivery is disabled.", latencyMs: nil)
    }

    do {
        try config.validatePrivateKey()
        return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
    } catch {
        req.logger.error("health.ready apns failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(status: "unhealthy", message: "APNS private key could not be parsed.", latencyMs: nil)
    }
}

private func marketDataHealthCheck(_: Request) -> HealthCheck {
    let hasFinnhub = !(Environment.get("FINNHUB_API_KEY") ?? "").isEmpty
    let hasIBKR = !(Environment.get("IBKR_API_BASE_URL") ?? "").isEmpty
    let hasFMP = !(Environment.get("FMP_API_KEY") ?? "").isEmpty
    if hasFinnhub || hasIBKR || hasFMP {
        return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
    }
    return HealthCheck(status: "degraded", message: "No live market-data provider is configured.", latencyMs: nil)
}

private func elapsedMilliseconds(since start: DispatchTime) -> Double {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return (Double(elapsed) / 1_000_000).rounded() / 1000
}

private func envBoolForHealth(_ key: String, default defaultValue: Bool) -> Bool {
    guard let rawValue = Environment.get(key)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return defaultValue
    }

    switch rawValue {
    case "1", "true", "yes", "y", "on":
        return true
    case "0", "false", "no", "n", "off":
        return false
    default:
        return defaultValue
    }
}

private func registerOpenAPIDocsRoutes(_ app: Application) throws {
    guard shouldExposeOpenAPIDocs(app) else {
        return
    }

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

private func shouldExposeOpenAPIDocs(_ app: Application) -> Bool {
    envBoolForHealth("API_DOCS_ENABLED", default: app.environment != .production)
}
