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
    app.marketDataService = DefaultMarketDataService(
        provider: IBKRMarketDataProvider(),
        cacheConfig: MarketDataCacheConfig.fromEnvironment()
    )
    app.statisticsRepository = DatabaseStatisticsRepository()
    app.statisticsService = DefaultStatisticsService(repo: app.statisticsRepository)
    app.newsRepository = DatabaseNewsRepository()
    app.newsService = DefaultNewsService(repo: app.newsRepository)
    app.dashboardRepository = DatabaseDashboardRepository()
    app.dashboardService = DefaultDashboardService(repo: app.dashboardRepository)
    app.userProfileRepository = DatabaseUserProfileRepository()
    app.userProfileService = DefaultUserProfileService(repo: app.userProfileRepository)

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
    app.migrations.add(CreateResearchNote())
    app.migrations.add(CreateTarget())
    app.migrations.add(CreatePriceHistory())
    app.migrations.add(CreateQuoteCache())
    app.migrations.add(CreateSearchCache())
    app.migrations.add(CreateStatisticsSnapshot())
    app.migrations.add(CreateBrokerConnection())
    app.migrations.add(CreateNewsItem())
    app.migrations.add(AddUserScopedQueryIndexes())

    // register routes
    try routes(app)
}
