// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StockPlanBackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🧩 FluentSQL helpers for SQL-backed Fluent migrations.
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.55.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🔐 JWT support.
        .package(url: "https://github.com/vapor/jwt.git", from: "5.0.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "StockPlanBackend",
            dependencies: [
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                // Telemetry
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .copy("openapi.yaml"),
            ],
            swiftSettings: swiftSettings,
            plugins: [
                            .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
                        ],
        ),
        .testTarget(
            name: "StockPlanBackendTests",
            dependencies: [
                .target(name: "StockPlanBackend"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
