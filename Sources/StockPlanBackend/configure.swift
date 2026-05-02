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

    // Idempotency for mutations — clients set Idempotency-Key header.
    // Caches POST/PUT/DELETE responses in Redis (24h TTL). No-op for other methods or missing header.
    app.middleware.use(IdempotencyMiddleware(ttl: 86400))

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

    let isTesting = app.environment == .testing
    let databaseHost = isTesting
        ? (Environment.get("TEST_DATABASE_HOST")
            ?? Environment.get("DATABASE_HOST")
            ?? "127.0.0.1")
        : (Environment.get("DATABASE_HOST") ?? "localhost")
    let databasePort = isTesting
        ? (Environment.get("TEST_DATABASE_PORT").flatMap(Int.init(_:))
            ?? Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
            ?? 5432)
        : (Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber)
    let databaseUsername = isTesting
        ? (Environment.get("TEST_DATABASE_USERNAME")
            ?? Environment.get("DATABASE_USERNAME")
            ?? "vapor_username")
        : (Environment.get("DATABASE_USERNAME") ?? "vapor_username")
    let databasePassword = isTesting
        ? (Environment.get("TEST_DATABASE_PASSWORD")
            ?? Environment.get("DATABASE_PASSWORD")
            ?? "vapor_password")
        : (Environment.get("DATABASE_PASSWORD") ?? "vapor_password")
    let databaseName = isTesting
        ? (Environment.get("TEST_DATABASE_NAME")
            ?? Environment.get("DATABASE_NAME")
            ?? "vapor_database")
        : (Environment.get("DATABASE_NAME") ?? "vapor_database")
    let testDatabaseSchema: String? = {
        guard isTesting else { return nil }
        if let configured = Environment.get("TEST_DATABASE_SCHEMA")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return configured.replacingOccurrences(
                of: #"[^a-zA-Z0-9_]"#,
                with: "_",
                options: .regularExpression
            )
        }

        return "stockplan_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"
    }()

    var postgresConfiguration = try SQLPostgresConfiguration(
        hostname: databaseHost,
        port: databasePort,
        username: databaseUsername,
        password: databasePassword,
        database: databaseName,
        tls: .prefer(.init(configuration: .clientDefault))
    )
    if let testDatabaseSchema {
        postgresConfiguration.searchPath = [testDatabaseSchema]
    }

    app.databases.use(
        DatabaseConfigurationFactory.postgres(configuration: postgresConfiguration),
        as: .psql
    )

    if let testDatabaseSchema,
       let sqlDatabase = app.db(.psql) as? any SQLDatabase
    {
        try await sqlDatabase.raw("CREATE SCHEMA IF NOT EXISTS \(unsafeRaw: testDatabaseSchema)").run()
    }

    if let redisURL = Environment.get("REDIS_URL"), !redisURL.isEmpty {
        app.redis.configuration = try RedisConfiguration(url: redisURL)
    }

    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret"
    await app.jwt.keys.add(hmac: HMACKey(from: jwtSecret), digestAlgorithm: .sha256)
    app.userPIIEncryptionService = try UserPIIEncryptionBootstrap.fromEnvironment(app: app)
    app.authRepository = DatabaseAuthRepository(encryptionService: app.userPIIEncryptionService)
    var oauthProviders: [OAuthProvider: any OAuthProviderClient] = [:]
    if let appleConfig = AppleOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.apple] = AppleOAuthProviderClient(config: appleConfig)
    } else {
        app.logger.warning("Apple OAuth is disabled. Configure OAUTH_APPLE_CLIENT_ID, OAUTH_APPLE_TEAM_ID, OAUTH_APPLE_KEY_ID, and OAUTH_APPLE_PRIVATE_KEY.")
    }
    if let googleConfig = GoogleOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.google] = GoogleOAuthProviderClient(config: googleConfig)
    } else {
        app.logger.warning("Google OAuth is disabled. Configure OAUTH_GOOGLE_CLIENT_ID and OAUTH_GOOGLE_CLIENT_SECRET.")
    }
    if let xConfig = XOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.x] = XOAuthProviderClient(config: xConfig)
    } else {
        app.logger.warning("X OAuth is disabled. Configure OAUTH_X_CLIENT_ID (and optionally OAUTH_X_CLIENT_SECRET).")
    }
    let mfaEnabled = envBool("AUTH_MFA_ENABLED", default: app.environment == .production)
    let mfaAllowLegacyBypass = envBool("AUTH_MFA_ALLOW_LEGACY_BYPASS", default: app.environment != .production)
    let mfaConfig = AuthMFAConfig(
        enabled: mfaEnabled,
        allowLegacyBypass: mfaAllowLegacyBypass,
        codeTTLSeconds: Environment.get("AUTH_MFA_CODE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 300,
        maxVerifyAttempts: Environment.get("AUTH_MFA_MAX_VERIFY_ATTEMPTS").flatMap(Int.init(_:)) ?? 5,
        resendCooldownSeconds: Environment.get("AUTH_MFA_RESEND_COOLDOWN_SECONDS").flatMap(Int.init(_:)) ?? 30,
        maxResends: Environment.get("AUTH_MFA_MAX_RESENDS").flatMap(Int.init(_:)) ?? 3
    )
    app.authService = DefaultAuthService(
        repo: app.authRepository,
        oauthProviders: oauthProviders,
        mfaConfig: mfaConfig,
        trialService: app.trialService
    )
    let resendAPIKey = Environment.get("RESEND_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resendFromEmail = Environment.get("RESEND_FROM_EMAIL")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resendBaseURLRaw = Environment.get("RESEND_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !resendAPIKey.isEmpty, !resendFromEmail.isEmpty {
        let resendBaseURL = URL(string: resendBaseURLRaw ?? "") ?? URL(string: "https://api.resend.com")!
        app.mailer = ResendMailerService(
            apiKey: resendAPIKey,
            fromEmail: resendFromEmail,
            baseURL: resendBaseURL
        )
    } else {
        if mfaEnabled, app.environment == .production {
            throw Abort(
                .internalServerError,
                reason: "MFA is enabled but RESEND_API_KEY and RESEND_FROM_EMAIL are not configured."
            )
        }
        app.mailer = ConsoleMailerService()
    }
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
    app.targetAlertEvaluator = DefaultTargetAlertEvaluator()

    if let apnsConfig = APNSBootstrapConfiguration.fromEnvironment(app: app) {
        try app.apns.configure(
            .jwt(
                privateKey: .loadFrom(string: apnsConfig.privateKeyP8),
                keyIdentifier: apnsConfig.keyID,
                teamIdentifier: apnsConfig.teamID
            )
        )
        app.pushNotificationSender = APNSPushNotificationSender(topic: apnsConfig.topic)
    } else {
        app.pushNotificationSender = NoopPushNotificationSender()
    }

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

    let cleanupIntervalMinutes = Environment.get("AUTH_TOKEN_CLEANUP_INTERVAL_MINUTES").flatMap(Int.init(_:)) ?? 60
    app.lifecycle.use(AuthTokenCleanup(interval: TimeInterval(cleanupIntervalMinutes * 60)))
    app.lifecycle.use(IBKRSyncJob())
    let apnsAlertPollSeconds = Environment.get("APNS_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 300
    app.lifecycle.use(TargetAlertPoller(intervalSeconds: apnsAlertPollSeconds))
    app.lifecycle.use(TrialExpirationJob())
    // Data Export cleanup (expire files after 7 days)
    app.lifecycle.use(DataExportCleanupJob(repository: app.dataExportRepository, interval: 86400))

    registerMigrations(app)

    // register routes
    try routes(app)
}

private func registerMigrations(_ app: Application) {
    app.migrations.add(CreateUser())
    app.migrations.add(AddAccountLockoutAndVerificationFields())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(DeleteFirstNameLastName())
    app.migrations.add(AddUserProfileMetadataFields())
    app.migrations.add(CreateGoal())
    app.migrations.add(AddGoalStatusFields())
    app.migrations.add(CreateAccount())
    app.migrations.add(CreateInstrument())
    app.migrations.add(CreateTransaction())
    app.migrations.add(CreateLot())
    app.migrations.add(CreatePosition())
    app.migrations.add(CreateCashBalance())
    app.migrations.add(CreateDividend())
    app.migrations.add(CreateFxRate())
    app.migrations.add(CreatePrice())
    app.migrations.add(CreatePasswordResetToken())
    app.migrations.add(AddPasswordResetTokenAttemptFields())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateMFAChallenge())
    app.migrations.add(CreateOAuthTables())
    app.migrations.add(CreateStock())
    app.migrations.add(AddAssetCategoryToStocks())
    app.migrations.add(AddImportSourceFieldsToStocks())
    app.migrations.add(CreateWatchlistItem())
    app.migrations.add(AddWatchlistMetadataFields())
    app.migrations.add(AddPortfolioAndWatchlistLists())
    app.migrations.add(CreateNewsItem())
    app.migrations.add(CreateResearchNote())
    app.migrations.add(CreateTarget())
    app.migrations.add(AddTargetAlertFields())
    app.migrations.add(CreatePushDevice())
    app.migrations.add(CreatePriceHistory())
    app.migrations.add(CreateQuoteCache())
    app.migrations.add(AddQuoteFields())
    app.migrations.add(CreateSearchCache())
    app.migrations.add(CreateStatisticsSnapshot())
    app.migrations.add(CreateBrokerConnection())
    app.migrations.add(AddBrokerOAuthFlowAndConnectionMetadata())
    app.migrations.add(CreateMarketNewsArchive())
    app.migrations.add(AddImageURLToMarketNewsArchive())
    app.migrations.add(AddUserScopedQueryIndexes())
    app.migrations.add(AddQuoteCacheLookupIndex())
    app.migrations.add(CreateStockValuation())
    app.migrations.add(CreateProfileCache())
    app.migrations.add(CreateBasicFinancialsCache())
    app.migrations.add(CreateAnalystEstimatesCache())
    app.migrations.add(CreateFinancialGrowthCache())
    app.migrations.add(CreateRatiosTTMCache())
    app.migrations.add(CreateRatiosCache())
    app.migrations.add(AddDatabaseOptimizations())
    app.migrations.add(CreateFeedback())
    app.migrations.add(CreateCryptoPortfolioItem())
    app.migrations.add(CreateExpensesTables())
    app.migrations.add(AddBudgetAlertThreshold())
    app.migrations.add(AddExpenseSharingFields())
    app.migrations.add(ConvertBudgetPillarEnumToString())
    app.migrations.add(CreateExpenseCategoryTable())
    app.migrations.add(CreateRecurringTemplatesTable())
    app.migrations.add(AddExpenseCurrencyFields())
    app.migrations.add(CreateReportSuggestionDismissals())
    app.migrations.add(AddHouseholdPartnerDisplayNameToUsers())
    app.migrations.add(AddEncryptedUserProfileFields())
    app.migrations.add(AddTrialFields())
    app.migrations.add(BackfillEncryptedUserProfileFields())
    app.migrations.add(CreateUserActivity())
    app.migrations.add(AddNewsViewedActivityType())
    app.migrations.add(CreateUserBadge())
    app.migrations.add(CreateBillingTables())
    app.migrations.add(CreateTrialWarning())
    app.migrations.add(CreateCoupons())
    app.migrations.add(AddCouponGrantType())
    app.migrations.add(CreateCouponRedemptions())
    app.migrations.add(CreateDataExport())
}

private func envBool(_ key: String, default defaultValue: Bool) -> Bool {
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
