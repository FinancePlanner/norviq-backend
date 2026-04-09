import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor
import JWT
import JWTKit
import Redis

// configures your application
public func configure(_ app: Application) async throws {
    if app.environment == .testing {
        app.logger.logLevel = .warning
    }

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.traceAutoPropagation = true
    // Clear all default middleware (then, add back route logging)
    app.middleware = .init()
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // cors middleware should come before default error middleware using `at: .beginning`
    app.middleware.use(cors, at: .beginning)
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
    // Add custom error handling middleware first.
    app.middleware.use(TracingMiddleware())

    // Configure global JSON decoder and encoder
    ContentConfiguration.global.use(decoder: JSONDecoder.stockPlanShared, for: .json)
    ContentConfiguration.global.use(encoder: JSONEncoder.stockPlanShared, for: .json)

    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
        tls: .prefer(try .init(configuration: .clientDefault)))
    ), as: .psql)

    if let redisURL = Environment.get("REDIS_URL"), !redisURL.isEmpty {
        app.redis.configuration = try RedisConfiguration(url: redisURL)
    }

    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret"
    await app.jwt.keys.add(hmac: HMACKey(from: jwtSecret), digestAlgorithm: .sha256)
    app.authRepository = DatabaseAuthRepository()
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
    app.authService = DefaultAuthService(
        repo: app.authRepository,
        oauthProviders: oauthProviders
    )
    app.mailer = ConsoleMailerService()
    app.stocksRepository = DatabaseStocksRepository()
    app.brokersRepository = DatabaseBrokersRepository()
    app.brokersService = DefaultBrokersService(repo: app.brokersRepository)
    app.marketDataRepository = DatabaseMarketDataRepository()
    let configuredMarketProvider = Environment.get("MARKET_PROVIDER")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let ibkrBaseURL = Environment.get("IBKR_API_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

    let fmpProvider: (any FMPMarketDataProvider & CryptoDataProvider)?
    if let fmpAPIKey, !fmpAPIKey.isEmpty {
        fmpProvider = LiveFMPMarketDataProvider(apiKey: fmpAPIKey)
    } else {
        fmpProvider = nil
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
    let newsProvider: (any NewsProvider)?
    if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        newsProvider = FinnhubNewsProvider(apiKey: finnhubAPIKey)
    } else {
        newsProvider = nil
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
    app.userProfileRepository = DatabaseUserProfileRepository()
    app.userProfileService = DefaultUserProfileService(repo: app.userProfileRepository)

    let earningsProvider: any EarningsProvider
    if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        earningsProvider = FinnhubEarningsProvider(apiKey: finnhubAPIKey)
    } else {
        earningsProvider = DisabledEarningsProvider()
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

    app.migrations.add(CreateUser())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(DeleteFirstNameLastName())
    app.migrations.add(AddUserProfileMetadataFields())

    app.migrations.add(AddGoalStatusFields())
    app.migrations.add(CreateAccount())
    app.migrations.add(CreateInstrument())
    app.migrations.add(CreateTransaction())
    app.migrations.add(CreateLot())
    app.migrations.add(CreatePosition())
    app.migrations.add(CreateCashBalance())
    app.migrations.add(CreateFxRate())
    app.migrations.add(CreatePrice())
    app.migrations.add(CreatePasswordResetToken())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateOAuthTables())
    app.migrations.add(CreateStock())
    app.migrations.add(AddAssetCategoryToStocks())
    app.migrations.add(CreateWatchlistItem())
    app.migrations.add(AddWatchlistMetadataFields())
    app.migrations.add(CreateResearchNote())
    app.migrations.add(CreateTarget())
    app.migrations.add(CreatePriceHistory())
    app.migrations.add(CreateQuoteCache())
    app.migrations.add(AddQuoteFields())
    app.migrations.add(CreateSearchCache())
    app.migrations.add(CreateStatisticsSnapshot())
    app.migrations.add(CreateBrokerConnection())
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
    app.migrations.add(AddExpenseSharingFields())
    app.migrations.add(CreateReportSuggestionDismissals())
    app.migrations.add(AddHouseholdPartnerDisplayNameToUsers())
    app.migrations.add(CreateUserActivity())
    app.migrations.add(AddNewsViewedActivityType())
    app.migrations.add(CreateUserBadge())

    // register routes
    try routes(app)
}
