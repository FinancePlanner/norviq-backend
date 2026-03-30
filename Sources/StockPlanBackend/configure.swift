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
    app.authService = DefaultAuthService(repo: app.authRepository)
    app.mailer = ConsoleMailerService()
    app.stocksRepository = DatabaseStocksRepository()
    app.stocksService = StockServiceImpl(repo: app.stocksRepository)
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

    app.marketDataService = DefaultMarketDataService(
        provider: marketProvider,
        cacheConfig: MarketDataCacheConfig.fromEnvironment()
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
    app.marketNewsArchiveService = DefaultMarketNewsArchiveService(provider: newsProvider)
    app.newsService = DefaultNewsService(repo: app.newsRepository, provider: newsProvider)
    app.dashboardRepository = DatabaseDashboardRepository()
    app.dashboardService = DefaultDashboardService(repo: app.dashboardRepository)
    app.userProfileRepository = DatabaseUserProfileRepository()
    app.userProfileService = DefaultUserProfileService(repo: app.userProfileRepository)

    let earningsProvider: any EarningsProvider
    if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        earningsProvider = FinnhubEarningsProvider(apiKey: finnhubAPIKey)
    } else {
        earningsProvider = DisabledEarningsProvider()
    }
    app.earningsService = DefaultEarningsService(provider: earningsProvider)

    let cleanupIntervalMinutes = Environment.get("AUTH_TOKEN_CLEANUP_INTERVAL_MINUTES").flatMap(Int.init(_:)) ?? 60
    app.lifecycle.use(AuthTokenCleanup(interval: TimeInterval(cleanupIntervalMinutes * 60)))

    app.migrations.add(CreateUser())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(AddUserProfileMetadataFields())
    app.migrations.add(CreateTodo())
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
    app.migrations.add(CreateStock())
    app.migrations.add(CreateWatchlistItem())
    app.migrations.add(AddWatchlistMetadataFields())
    app.migrations.add(CreateResearchNote())
    app.migrations.add(CreateTarget())
    app.migrations.add(CreatePriceHistory())
    app.migrations.add(CreateQuoteCache())
    app.migrations.add(CreateSearchCache())
    app.migrations.add(CreateStatisticsSnapshot())
    app.migrations.add(CreateBrokerConnection())
    app.migrations.add(CreateMarketNewsArchive())
    app.migrations.add(CreateNewsItem())
    app.migrations.add(AddUserScopedQueryIndexes())
    app.migrations.add(CreateStockValuation())

    // register routes
    try routes(app)
}
