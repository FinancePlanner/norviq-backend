import APNS
import APNSCore
import Fluent
import FluentPostgresDriver
import FluentSQL
import JWT
import JWTKit
import Metrics
import NIOSSL
import Redis
import Vapor
import VaporAPNS

/// configures your application
public func configure(_ app: Application) async throws {
    try ProductionConfiguration.validate(for: app)

    if app.environment == .testing {
        app.logger.logLevel = .warning
    }

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.traceAutoPropagation = true
    app.routes.defaultMaxBodySize = "10mb"
    // Clear all default middleware (then, add back route logging)
    app.middleware = .init()
    let allowedOrigins = try ProductionConfiguration.allowedOrigins(
        from: Environment.get("ALLOWED_ORIGINS"),
        isProduction: app.environment == .production
    )
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .any(allowedOrigins), // In production, this should be more restricted.
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // cors middleware should come before default error middleware using `at: .beginning`
    app.middleware.use(cors, at: .beginning)
    // Add Vary: Origin for correct CDN caching when CORS is enabled.
    app.middleware.use(VaryHeaderMiddleware())
    // Enable response compression (gzip/deflate) with 1KB threshold
    app.http.server.configuration.responseCompression = .enabled(initialByteBufferCapacity: 1024)
    app.middleware.use(ResponseCompressionMiddleware(override: .useDefault))
    app.middleware.use(APIErrorMiddleware())
    app.middleware.use(BillingErrorMiddleware())

    app.middleware.use(RequestLoggingMiddleware())
    // Add custom error handling middleware first.
    app.middleware.use(TracingMiddleware())

    // Configure global JSON decoder and encoder
    ContentConfiguration.global.use(decoder: JSONDecoder.backendAPI, for: .json)
    ContentConfiguration.global.use(encoder: JSONEncoder.backendAPI, for: .json)

    // === Prometheus Metrics (lightweight custom exporter) ===
    // Enabled by env PROMETHEUS_ENABLED=1 (off by default)
    if envBool("PROMETHEUS_ENABLED", default: false) {
        // Register HTTP metrics middleware early (before route logging)
        app.middleware.use(HTTPMetricsMiddleware(), at: .beginning)

        // Register business metrics service (singleton)
        app.businessMetrics = BusinessMetrics.shared

        // Expose /metrics endpoint
        try app.register(collection: MetricsController())
    }

    if envBool("OBS_TRACES_ENABLED", default: false) {
        let serviceName = Environment.get("OBS_SERVICE_NAME") ?? "StockPlanBackend"
        let environmentName = Environment.get("OBS_ENVIRONMENT") ?? app.environment.name
        let endpoint = Environment.get("OBS_OTLP_ENDPOINT") ?? "not-configured"
        app.logger.info(
            "observability.tracing enabled service=\(serviceName) environment=\(environmentName) otlp_endpoint=\(endpoint)"
        )
    }

    try await configurePersistence(app)
    try await configureAuthStack(app)

    let ibkrBaseURL = Environment.get("IBKR_API_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    app.stocksRepository = DatabaseStocksRepository()
    app.brokersRepository = DatabaseBrokersRepository()
    app.brokersService = DefaultBrokersService(
        repo: app.brokersRepository,
        ibkrGatewayClient: IBKRBrokerGatewayClient(
            baseURL: ibkrBaseURL ?? "http://localhost:5000/v1/api",
            defaultCurrency: Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
        )
    )
    app.marketDataRepository = DatabaseMarketDataRepository()
    let configuredMarketProvider = Environment.get("MARKET_PROVIDER")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let finnhubAPIKey = Environment.get("FINNHUB_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let fmpAPIKey = Environment.get("FMP_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let marketProvider: any MarketDataProvider
    switch configuredMarketProvider {
    case "finnhub":
        if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
            marketProvider = FinnhubMarketDataProvider(apiKey: finnhubAPIKey)
        } else {
            app.logger.warning("MARKET_PROVIDER=finnhub but FINNHUB_API_KEY is not configured; market data disabled.")
            marketProvider = DisabledMarketDataProvider()
        }

    case "ibkr":
        if let ibkrBaseURL, !ibkrBaseURL.isEmpty {
            marketProvider = IBKRMarketDataProvider(baseURL: ibkrBaseURL)
        } else {
            app.logger.warning("MARKET_PROVIDER=ibkr but IBKR_API_BASE_URL is not configured; market data disabled.")
            marketProvider = DisabledMarketDataProvider()
        }

    default:
        if let ibkrBaseURL, !ibkrBaseURL.isEmpty {
            marketProvider = IBKRMarketDataProvider(baseURL: ibkrBaseURL)
        } else if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
            marketProvider = FinnhubMarketDataProvider(apiKey: finnhubAPIKey)
        } else {
            marketProvider = DisabledMarketDataProvider()
        }
    }

    let fmpProvider: (any FMPMarketDataProvider & CryptoDataProvider)? = if let fmpAPIKey, !fmpAPIKey.isEmpty {
        LiveFMPMarketDataProvider(apiKey: fmpAPIKey)
    } else {
        nil
    }

    app.marketDataService = DefaultMarketDataService(
        provider: marketProvider,
        fmpProvider: fmpProvider,
        cacheConfig: MarketDataCacheConfig.fromEnvironment(),
        fmpAccessTier: FMPAccessTier.fromEnvironment()
    )
    app.statisticsRepository = DatabaseStatisticsRepository()
    app.statisticsService = DefaultStatisticsService(repo: app.statisticsRepository)
    app.newsRepository = DatabaseNewsRepository()
    let newsProvider: (any NewsProvider)? = if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        FinnhubNewsProvider(apiKey: finnhubAPIKey)
    } else {
        nil
    }
    app.marketNewsArchiveService = DefaultMarketNewsArchiveService(
        provider: newsProvider,
        fmpProvider: app.marketDataService.fmpProvider
    )
    app.newsService = DefaultNewsService(repo: app.newsRepository, provider: newsProvider)
    app.dashboardRepository = DatabaseDashboardRepository()
    app.dashboardService = DefaultDashboardService(
        repo: app.dashboardRepository,
        statisticsRepo: app.statisticsRepository
    )
    app.userProfileRepository = DatabaseUserProfileRepository(encryptionService: app.userPIIEncryptionService)
    app.userProfileService = DefaultUserProfileService(repo: app.userProfileRepository)
    app.pushDeviceService = DatabasePushDeviceService()
    app.earningsNotificationPreferenceService = DatabaseEarningsNotificationPreferenceService()
    app.earningsNotificationEvaluator = DefaultEarningsNotificationEvaluator()
    // Data Export service setup
    app.dataExportRepository = DatabaseDataExportRepository()
    app.exportService = ExportService(repository: app.dataExportRepository, application: app)
    app.dataExportService = DefaultDataExportService(repository: app.dataExportRepository, exporter: app.exportService)
    let premiumEmails = Set(
        (Environment.get("BILLING_PREMIUM_EMAILS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    )
    app.entitlementResolver = DefaultEntitlementResolver(environment: app.environment, premiumEmails: premiumEmails)
    app.usageCounterService = DefaultUsageCounterService(entitlementResolver: app.entitlementResolver)
    app.billingContextService = DefaultBillingContextService(
        entitlementResolver: app.entitlementResolver,
        usageCounterService: app.usageCounterService,
        trialService: app.trialService
    )
    app.billingService = DefaultBillingService()
    try validateBillingSecrets(app)
    app.targetAlertEvaluator = DefaultTargetAlertEvaluator()

    try configureAPNS(app)

    let earningsProvider: any EarningsProvider = if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        FinnhubEarningsProvider(apiKey: finnhubAPIKey)
    } else {
        DisabledEarningsProvider()
    }
    app.earningsService = DefaultEarningsService(provider: earningsProvider)

    if let fmpProvider {
        app.cryptoService = DefaultCryptoService(provider: fmpProvider)
    } else {
        app.logger.warning("FMP_API_KEY is not configured; using MockCryptoDataProvider for market data.")
        app.cryptoService = DefaultCryptoService(provider: MockCryptoDataProvider())
    }

    // AI insights (educational, Pro-gated). Backend proxy to OpenAI; key never
    // leaves the server. Boots disabled when no key is configured.
    app.aiInsightsService = DefaultAIInsightsService(client: makeOpenAIChatClient(app))

    let cleanupIntervalMinutes = Environment.get("AUTH_TOKEN_CLEANUP_INTERVAL_MINUTES").flatMap(Int.init(_:)) ?? 60
    app.lifecycle.use(AuthTokenCleanup(interval: TimeInterval(cleanupIntervalMinutes * 60)))
    app.lifecycle.use(IBKRSyncJob())
    let apnsAlertPollSeconds = Environment.get("APNS_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 300
    app.lifecycle.use(TargetAlertPoller(intervalSeconds: apnsAlertPollSeconds))
    let earningsAlertPollSeconds = Environment.get("EARNINGS_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 86400
    app.lifecycle.use(EarningsNotificationPoller(intervalSeconds: earningsAlertPollSeconds))
    app.lifecycle.use(TrialExpirationJob())
    // Data Export cleanup (expire files after 7 days)
    app.lifecycle.use(DataExportCleanupJob(repository: app.dataExportRepository, interval: 86400))

    registerMigrations(app)

    // register routes
    try routes(app)
}

/// Fail-fast validation of billing secrets at boot.
///
/// A missing `REVENUECAT_WEBHOOK_SECRET` makes `/webhooks/revenuecat` return 503 for every
/// delivery, silently dropping purchase events so paying users are never granted pro. A missing
/// `REVENUECAT_API_KEY` breaks the `/billing/restore` recovery path. In production we refuse to
/// boot so the misconfiguration surfaces at deploy time instead of as lost revenue; elsewhere we
/// log a loud warning.
func validateBillingSecrets(_ app: Application) throws {
    let required = [
        "REVENUECAT_WEBHOOK_SECRET",
        "REVENUECAT_API_KEY",
    ]
    let missing = required.filter { name in
        (Environment.get(name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
    guard !missing.isEmpty else { return }

    let list = missing.joined(separator: ", ")
    if app.environment == .production {
        app.logger.critical("Missing required billing secrets: \(list). Refusing to boot.")
        throw Abort(.internalServerError, reason: "Missing required billing secrets: \(list).")
    } else {
        app.logger.warning("Billing secrets not configured: \(list). RevenueCat webhooks and restore will not work.")
    }
}

func configureAPNS(_ app: Application) throws {
    guard let apnsConfig = APNSBootstrapConfiguration.fromEnvironment(app: app) else {
        app.pushNotificationSender = NoopPushNotificationSender()
        return
    }

    do {
        try apnsConfig.validatePrivateKey()
        try app.apns.configure(
            .jwt(
                privateKey: .loadFrom(string: apnsConfig.privateKeyP8),
                keyIdentifier: apnsConfig.keyID,
                teamIdentifier: apnsConfig.teamID
            )
        )
        app.pushNotificationSender = APNSPushNotificationSender(topic: apnsConfig.topic)
    } catch {
        guard app.environment != .production else {
            throw error
        }

        app.logger.warning(
            "APNS is disabled because APNS_PRIVATE_KEY_P8 could not be parsed in \(app.environment.name): \(String(describing: error))"
        )
        app.pushNotificationSender = NoopPushNotificationSender()
    }
}
