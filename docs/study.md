# Study Guide: Swift + Vapor + SwiftUI

This guide is for getting comfortable building Swift APIs and iOS apps end to end.
It is practical by design: learn a concept, then apply it to a small feature.

## What "Comfortable" Means

You can independently:
- design and implement a REST API in Vapor
- model and migrate data with Fluent
- secure endpoints with JWT auth and middleware
- build a SwiftUI app that consumes your API with async/await
- debug, test, and ship both backend and app with confidence

##  1) Swift Language Foundations (Non-Negotiable)

Learn these first because Vapor and SwiftUI both depend on them.

### Core language and type system
- `struct`, `class`, `enum`, `protocol`
- value vs reference semantics
- optionals and `guard let`
- `mutating`, `inout`, computed properties
- access control (`private`, `fileprivate`, `internal`, `public`)

Example:
Run context: `Swift playground` or `SwiftPM executable target`.
```swift
import Foundation

struct Position {
    let symbol: String
    var shares: Decimal
    var lastPrice: Decimal?

    var marketValue: Decimal {
        guard let lastPrice else { return 0 }
        return shares * lastPrice
    }

    mutating func buy(_ quantity: Decimal) {
        shares += quantity
    }
}

class PortfolioStore {
    var positions: [Position] = []
}

enum OrderSide: String {
    case buy
    case sell
}

protocol QuoteProvider {
    func quote(for symbol: String) async throws -> Decimal
}

var original = Position(symbol: "AAPL", shares: 10, lastPrice: 190)
var copied = original
copied.buy(2)
```

What is actually happening:
- `Position` is a value type (`struct`), so `copied` changes do not mutate `original`.
- `PortfolioStore` is a reference type (`class`), so multiple references see the same mutations.
- `lastPrice` is optional; `guard let` safely handles the `nil` case.
- `marketValue` is a computed property, evaluated each time you read it.
- `buy(_:)` is `mutating` because it changes stored data inside a `struct`.

### Error handling and safety
- `throws`, `do/catch`, custom error types
- `Result` and when to use it
- defensive coding with early return

Example:
Run context: `Swift playground` or `SwiftPM executable target`.
```swift
import Foundation

enum StockInputError: LocalizedError {
    case invalidSymbol
    case invalidShares

    var errorDescription: String? {
        switch self {
        case .invalidSymbol: return "Symbol must be 1-10 uppercase letters."
        case .invalidShares: return "Shares must be greater than zero."
        }
    }
}

func validate(symbol: String, shares: Decimal) throws {
    let okSymbol = symbol.range(of: #"^[A-Z]{1,10}$"#, options: .regularExpression) != nil
    guard okSymbol else { throw StockInputError.invalidSymbol }
    guard shares > 0 else { throw StockInputError.invalidShares }
}

func normalizedSymbol(from raw: String) -> Result<String, Error> {
    Result {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        try validate(symbol: symbol, shares: 1)
        return symbol
    }
}

do {
    try validate(symbol: "AAPL", shares: 5)
} catch {
    print(error.localizedDescription)
}
```

What is actually happening:
- `throws` models expected failure paths explicitly.
- `guard` exits early on invalid input, so bad data never reaches deeper logic.
- `Result` wraps success/failure into one value, useful for callback APIs and composition.
- Custom errors keep failure reasons clear for logs and API responses.

### Concurrency (critical)
- `async/await`
- structured concurrency (`Task`, `async let`, task groups)
- actors and data-race prevention
- `Sendable` and why it matters in modern Swift codebases

Example:
Run context: `Swift playground` or `SwiftPM executable target`.
```swift
import Foundation

protocol PricingClient: Sendable {
    func quote(for symbol: String) async throws -> Decimal
}

actor QuoteCache {
    private var storage: [String: Decimal] = [:]

    func get(_ symbol: String) -> Decimal? { storage[symbol] }
    func set(_ symbol: String, price: Decimal) { storage[symbol] = price }
}

func loadQuotes(
    symbols: [String],
    pricing: some PricingClient
) async throws -> [String: Decimal] {
    try await withThrowingTaskGroup(of: (String, Decimal).self) { group in
        for symbol in symbols {
            group.addTask {
                (symbol, try await pricing.quote(for: symbol))
            }
        }

        var output: [String: Decimal] = [:]
        for try await (symbol, price) in group {
            output[symbol] = price
        }
        return output
    }
}
```

What is actually happening:
- The task group launches one child task per symbol and waits for all of them.
- Requests run concurrently, reducing total wait time versus sequential fetches.
- `actor QuoteCache` serializes access to `storage`, preventing data races.
- `Sendable` on `PricingClient` signals that values crossing concurrency boundaries are safe.

### Protocol-oriented programming
- protocol-based abstractions
- protocol extensions
- dependency injection through protocols

Example:
Run context: `Swift playground` or `SwiftPM executable target`.
```swift
import Foundation

struct Stock {
    let symbol: String
}

protocol StocksRepository {
    func find(symbol: String, userId: UUID) async throws -> Stock?
    func save(_ stock: Stock, userId: UUID) async throws
}

extension StocksRepository {
    func exists(symbol: String, userId: UUID) async throws -> Bool {
        try await find(symbol: symbol, userId: userId) != nil
    }
}

struct StocksService {
    let repo: any StocksRepository

    func addIfMissing(symbol: String, userId: UUID) async throws {
        guard try await !repo.exists(symbol: symbol, userId: userId) else { return }
        try await repo.save(Stock(symbol: symbol), userId: userId)
    }
}
```

What is actually happening:
- Business logic (`StocksService`) depends on a protocol, not a concrete database type.
- You can inject a real repo in production and a mock repo in tests.
- The protocol extension provides shared helper logic once (`exists`), reusable by all repos.

### Codable and JSON
- `Codable`, custom `CodingKeys`
- decoding/encoding dates and decimals
- resilient decoding for partially missing fields

Example:
Run context: `Swift playground` or `SwiftPM executable target`.
```swift
import Foundation

struct QuoteDTO: Codable {
    let symbol: String
    let price: Decimal
    let asOf: Date
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case symbol
        case price
        case asOf = "as_of"
        case currency
    }
}

let json = #"{"symbol":"AAPL","price":196.45,"as_of":"2026-02-08T10:00:00Z"}"#
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

let quote = try decoder.decode(QuoteDTO.self, from: Data(json.utf8))
print(quote.symbol)
```

What is actually happening:
- `CodingKeys` maps snake_case JSON (`as_of`) to Swift-style properties (`asOf`).
- ISO-8601 strategy parses API date strings directly into `Date`.
- `currency` is optional, so decode still succeeds when that field is missing.

### Swift Package Manager and tests
- package structure and targets
- writing focused unit tests with XCTest
- test doubles for repositories/services

Example:
Run context: `SwiftPM test target` (for example `Tests/...`).
```swift
import Foundation
import XCTest

protocol QuoteRepository {
    func fetch(_ symbol: String) async throws -> Decimal
}

struct QuoteService {
    let repo: any QuoteRepository

    func load(_ symbol: String) async throws -> Decimal {
        try await repo.fetch(symbol)
    }
}

struct MockQuoteRepository: QuoteRepository {
    let values: [String: Decimal]

    func fetch(_ symbol: String) async throws -> Decimal {
        values[symbol] ?? 0
    }
}

final class QuoteServiceTests: XCTestCase {
    func testLoadReturnsMockedPrice() async throws {
        let service = QuoteService(repo: MockQuoteRepository(values: ["AAPL": 190]))
        let price = try await service.load("AAPL")
        XCTAssertEqual(price, 190)
    }
}
```

What is actually happening:
- The test isolates service behavior without network or database access.
- The mock repository returns deterministic values, making tests fast and stable.
- XCTest verifies the contract: given input symbol, service returns expected price.

## 2) Vapor Essentials for API Development

### Application lifecycle
- `configure.swift` setup flow
- route registration and grouped routes
- environment-driven configuration

Example:
Run context: `Vapor backend target` (for example `Sources/StockPlanBackend/configure.swift`).
```swift
import Vapor
import JWT
import Fluent

protocol BrokersRepository {}
struct DatabaseBrokersRepository: BrokersRepository {}

protocol BrokersService {}
struct DefaultBrokersService: BrokersService {
    init(repo: any BrokersRepository) {}
}

struct CreateBrokerConnection: AsyncMigration {
    func prepare(on db: any Database) async throws {}
    func revert(on db: any Database) async throws {}
}

extension Application {
    struct BrokersRepositoryKey: StorageKey {
        typealias Value = any BrokersRepository
    }

    struct BrokersServiceKey: StorageKey {
        typealias Value = any BrokersService
    }

    var brokersRepository: any BrokersRepository {
        get { storage[BrokersRepositoryKey.self]! }
        set { storage[BrokersRepositoryKey.self] = newValue }
    }

    var brokersService: any BrokersService {
        get { storage[BrokersServiceKey.self]! }
        set { storage[BrokersServiceKey.self] = newValue }
    }
}

func routes(_ app: Application) throws {}

public func configure(_ app: Application) async throws {
    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret"
    await app.jwt.keys.add(hmac: HMACKey(from: jwtSecret), digestAlgorithm: .sha256)

    app.brokersRepository = DatabaseBrokersRepository()
    app.brokersService = DefaultBrokersService(repo: app.brokersRepository)

    app.migrations.add(CreateBrokerConnection())
    try routes(app)
}
```

What is actually happening:
- `configure` is startup wiring: dependencies, auth keys, migrations, and routes.
- Environment variables let you switch config per environment without code changes.
- Dependencies are registered once and reused by requests.

### Routing and request handling
- route collections/controllers
- request decoding and response encoding
- query/path/body parsing
- status codes and API consistency

Example:
Run context: `Vapor backend target` (for example a controller in `Sources/StockPlanBackend/...`).
```swift
import Vapor

struct StockRequest: Content {
    let symbol: String
    let shares: Double
}

struct StockResponse: Content {
    let id: UUID
    let symbol: String
    let shares: Double
}

struct StocksController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let stocks = routes.grouped("stocks")
        stocks.post(use: create)
        stocks.get(":stockId", use: get)
    }

    func create(req: Request) async throws -> HTTPStatus {
        let payload = try req.content.decode(StockRequest.self)
        guard payload.shares > 0 else {
            throw Abort(.badRequest, reason: "shares must be > 0")
        }
        // Persist using a service/repository
        return .created
    }

    func get(req: Request) async throws -> StockResponse {
        guard let stockId = req.parameters.get("stockId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid stock id")
        }
        // Fetch by id and return DTO
        return StockResponse(id: stockId, symbol: "AAPL", shares: 1)
    }
}
```

What is actually happening:
- `boot` maps HTTP method + path to controller functions.
- `req.content.decode` turns JSON body into typed Swift data.
- Path params are parsed and validated before querying data.
- Abort errors produce proper status codes and client-safe messages.

### Middleware and auth
- authentication vs authorization
- JWT token lifecycle
- protected route groups
- request-scoped user identity

Example:
Run context: `Vapor backend target` (routes + middleware files).
```swift
import Vapor

struct SessionToken: Authenticatable {
    let userId: UUID
}

struct SessionAuthenticator: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if req.headers.bearerAuthorization != nil {
            req.auth.login(SessionToken(userId: UUID()))
        }
        return try await next.respond(to: req)
    }
}

struct SessionGuard: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard req.auth.has(SessionToken.self) else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: req)
    }
}

func routes(_ app: Application) throws {
    let protected = app.grouped(
        SessionAuthenticator(),
        SessionGuard()
    )

    protected.get("me") { req async throws -> [String: String] in
        let session = try req.auth.require(SessionToken.self)
        return ["userId": session.userId.uuidString]
    }
}
```

What is actually happening:
- `SessionAuthenticator` reads token credentials and, if valid, stores user info on `req.auth`.
- `SessionGuard` blocks unauthorized requests before reaching handler logic.
- Handler code retrieves the authenticated identity from request scope.
- Authentication answers "who are you"; authorization adds "can you do this action."

### Data layer with Fluent
- models, fields, and schema migrations
- one-to-many and many-to-many relationships
- query building and pagination
- transaction boundaries and idempotency

Example:
Run context: `Vapor backend target` with `Fluent` models and migrations.
```swift
import Fluent
import Vapor

final class User: Model {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String

    init() {}
    init(id: UUID? = nil, email: String) {
        self.id = id
        self.email = email
    }
}

final class Stock: Model, Content {
    static let schema = "stocks"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "symbol") var symbol: String
    @Field(key: "shares") var shares: Double

    init() {}
}

struct CreateStock: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(Stock.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id))
            .field("symbol", .string, .required)
            .field("shares", .double, .required)
            .unique(on: "user_id", "symbol")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(Stock.schema).delete()
    }
}
```

What is actually happening:
- The model defines how Swift properties map to DB columns.
- Migration creates the actual table and constraints in the database.
- `@Parent` sets a relationship to owner user, enabling ownership queries.
- Unique constraint enforces one row per `(user_id, symbol)` at DB level.

### Architecture patterns used in this repo
- repository layer for persistence concerns
- service layer for business logic
- `Application` storage keys for dependency wiring
- thin controllers, fat services

Example:
Run context: `Vapor backend target` (service + repository wiring).
```swift
import Vapor
import Fluent

struct StockModel {
    let id: UUID?
    let symbol: String
    let shares: Double
}

struct StockResponse: Content {
    let id: UUID
    let symbol: String
    let shares: Double
}

protocol StocksRepository {
    func list(userId: UUID, on db: any Database) async throws -> [StockModel]
}

protocol StockService {
    func list(userId: UUID, on db: any Database) async throws -> [StockResponse]
}

struct StockServiceImpl: StockService {
    let repo: any StocksRepository

    func list(userId: UUID, on db: any Database) async throws -> [StockResponse] {
        let models = try await repo.list(userId: userId, on: db)
        return models.map {
            StockResponse(id: $0.id ?? UUID(), symbol: $0.symbol, shares: $0.shares)
        }
    }
}

extension Application {
    struct StockServiceKey: StorageKey { typealias Value = any StockService }
    var stocksService: any StockService {
        get { storage[StockServiceKey.self]! }
        set { storage[StockServiceKey.self] = newValue }
    }
}
```

What is actually happening:
- Repository hides database details from business logic.
- Service applies business rules and maps models to API DTOs.
- Controller can stay small and call `req.application.stocksService`.
- App storage key wires implementation once at startup.

### Operational concerns
- input validation
- structured logging
- error mapping (internal errors vs client-safe messages)
- database migration discipline

Example:
Run context: `Vapor backend target` (controller/service entry point).
```swift
import Vapor

struct StockRequest: Content {
    let symbol: String
    let shares: Double
}

func createStock(req: Request) async throws -> HTTPStatus {
    let payload = try req.content.decode(StockRequest.self)

    guard payload.shares > 0 else {
        throw Abort(.badRequest, reason: "shares must be > 0")
    }

    req.logger.info("create_stock symbol=\(payload.symbol)")

    do {
        // Persist entity
        return .created
    } catch {
        req.logger.error("create_stock_failed error=\(error.localizedDescription)")
        throw Abort(.internalServerError, reason: "Unable to create stock right now.")
    }
}
```

What is actually happening:
- Validation stops bad requests before they hit persistence.
- Logs capture context (`symbol`) for debugging production issues.
- Internal exception details stay in logs, while clients get safe generic messages.
- This keeps API behavior predictable and secure.

## 3) SwiftUI Essentials for iOS Apps

### UI composition
- `View` composition, modifiers, and reusable components
- `NavigationStack`, sheets, and full-screen flows
- forms, lists, and empty/loading/error states

Example:
Run context: `iOS SwiftUI app target`.
```swift
import SwiftUI

struct StockRow: Identifiable {
    let id = UUID()
    let symbol: String
    let shares: Double
}

@MainActor
final class StocksViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isCreatePresented = false
    @Published var items: [StockRow] = []
}

struct StocksListView: View {
    @StateObject private var vm = StocksViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Loading...")
                } else if vm.items.isEmpty {
                    ContentUnavailableView("No Stocks", systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    List(vm.items) { item in
                        VStack(alignment: .leading) {
                            Text(item.symbol).font(.headline)
                            Text("\(item.shares, specifier: "%.2f") shares")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Portfolio")
            .toolbar { Button("Add") { vm.isCreatePresented = true } }
            .sheet(isPresented: $vm.isCreatePresented) {
                Text("Create Form")
            }
        }
    }
}
```

What is actually happening:
- `NavigationStack` owns navigation state for push-based flows.
- `Group` conditionally switches between loading/empty/data UI states.
- `sheet` presents modal flow for creation without leaving list context.
- View updates reactively when observed state changes.

### State management
- `@State`, `@Binding`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`
- when to keep state local vs shared
- one-way data flow in practice

Example:
Run context: `iOS SwiftUI app target`.
```swift
import SwiftUI

struct ParentView: View {
    @State private var symbol = ""
    @StateObject private var session = SessionStore()

    var body: some View {
        ChildForm(symbol: $symbol)
            .environmentObject(session)
    }
}

struct ChildForm: View {
    @Binding var symbol: String

    var body: some View {
        TextField("Symbol", text: $symbol)
    }
}

final class SessionStore: ObservableObject {
    @Published var token: String?
}
```

What is actually happening:
- `@State` owns local mutable state in `ParentView`.
- `@Binding` lets child mutate parent-owned state.
- `@StateObject` creates and retains one observable instance for the view lifecycle.
- `@EnvironmentObject` shares app-level state through subtree injection.

### Concurrency in UI
- `.task`, cancellation, and refresh behavior
- main actor updates for UI state
- handling parallel API requests safely

Example:
Run context: `iOS SwiftUI app target`.
```swift
import SwiftUI

struct StockRow: Identifiable {
    let id = UUID()
    let symbol: String
}

protocol StocksAPI {
    func listStocks() async throws -> [StockRow]
    func listWatchlist() async throws -> [String]
}

struct LiveStocksAPI: StocksAPI {
    func listStocks() async throws -> [StockRow] {
        [StockRow(symbol: "AAPL"), StockRow(symbol: "MSFT")]
    }

    func listWatchlist() async throws -> [String] {
        ["NVDA", "AMZN"]
    }
}

@MainActor
final class StocksViewModel: ObservableObject {
    @Published var items: [StockRow] = []
    @Published var isLoading = false
    let api: any StocksAPI

    init(api: any StocksAPI = LiveStocksAPI()) {
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let stocks = api.listStocks()
            async let watchlist = api.listWatchlist()
            items = try await stocks
            _ = try await watchlist
        } catch is CancellationError {
            // User navigated away or task was replaced.
        } catch {
            items = []
        }
    }
}

struct StocksScreen: View {
    @StateObject private var vm = StocksViewModel()

    var body: some View {
        List(vm.items) { row in
            Text(row.symbol)
        }
        .task { await vm.load() }
    }
}
```

What is actually happening:
- `.task` starts async work when view appears.
- `@MainActor` guarantees UI state mutations happen on main thread.
- `async let` runs independent network calls concurrently.
- Cancellation is treated as normal control flow, not a crash path.

### Networking
- `URLSession` with async/await
- typed request/response models
- auth token handling and refresh strategy
- centralized API client and endpoint definitions

Example:
Run context: `iOS app target` or a shared client module used by iOS.
```swift
import Foundation

enum APIError: Error {
    case invalidResponse
    case http(Int)
}

struct APIClient {
    let baseURL: URL
    let tokenProvider: () -> String?

    func send<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
```

What is actually happening:
- A single client centralizes headers, auth, decode rules, and status handling.
- Generic `send<T>` avoids copy-paste code per endpoint.
- Non-2xx status is mapped to typed errors for clean UI handling.

### App architecture
- feature-oriented folders/modules
- view model boundaries
- dependency injection for API clients and stores
- testable design

Example:
Run context: `iOS SwiftUI app target` (app entry point + dependency container).
```swift
import SwiftUI

struct APIClient {
    let baseURL: URL
    let tokenProvider: () -> String?
}

final class SessionStore: ObservableObject {
    @Published var token: String?
}

struct RootView: View {
    let api: APIClient

    var body: some View {
        Text("Base URL: \(api.baseURL.absoluteString)")
            .padding()
    }
}

enum AppContainer {
    static let api = APIClient(
        baseURL: URL(string: "http://localhost:8080")!,
        tokenProvider: { nil }
    )
}

@main
struct StockPlanApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(api: AppContainer.api)
                .environmentObject(session)
        }
    }
}
```

What is actually happening:
- Root composition defines app-wide dependencies once.
- Features receive dependencies explicitly (`RootView(api:)`), which improves testability.
- Shared session state is injected where needed via environment object.

## 4) Full-Stack Integration Skills (Where Most Teams Struggle)

### Contract-first thinking
- keep backend DTOs and iOS models aligned
- define date and number formats once and enforce them
- standardize API error payloads

Example:
Run context: Split by layer: backend DTOs in `Vapor backend target`; client DTOs in `iOS app target`.
```swift
import Vapor
import Foundation

// Backend response contract
struct StockResponse: Content {
    let id: UUID
    let symbol: String
    let shares: Double
    let buyDate: String // YYYY-MM-DD
}

struct APIErrorResponse: Content {
    let error: Bool
    let code: String
    let reason: String
}

// iOS model mirrors the same JSON keys/types
struct StockDTO: Decodable {
    let id: UUID
    let symbol: String
    let shares: Double
    let buyDate: String
}
```

What is actually happening:
- Both backend and iOS agree on field names, shapes, and formats.
- Date format (`YYYY-MM-DD`) is explicit, reducing decode ambiguity.
- Standardized error payload enables one reusable UI error parser.

### Data consistency and UX
- optimistic updates vs server truth
- retry behavior and offline scenarios
- idempotent writes from flaky mobile networks

Example:
Run context: `iOS SwiftUI app target` (view model + API client contract).
```swift
import Foundation
import SwiftUI

struct StockRow: Identifiable {
    let id: UUID
    let symbol: String
    let shares: Double
    let isPending: Bool
}

protocol StocksAPI {
    func createStock(symbol: String, shares: Double, idempotencyKey: String) async throws -> StockRow
}

@MainActor
final class StocksViewModel: ObservableObject {
    @Published var items: [StockRow] = []
    @Published var errorMessage: String?
    let api: any StocksAPI

    init(api: any StocksAPI) { self.api = api }

    func create(symbol: String, shares: Double) async {
        let temp = StockRow(id: UUID(), symbol: symbol, shares: shares, isPending: true)
        items.insert(temp, at: 0)

        do {
            let saved = try await api.createStock(
                symbol: symbol,
                shares: shares,
                idempotencyKey: UUID().uuidString
            )
            if let index = items.firstIndex(where: { $0.id == temp.id }) {
                items[index] = saved
            }
        } catch {
            items.removeAll { $0.id == temp.id }
            errorMessage = "Could not save stock. Please try again."
        }
    }
}
```

What is actually happening:
- UI updates instantly (optimistic) for snappy UX.
- If server call fails, local optimistic row is rolled back.
- Idempotency key lets server safely ignore duplicate retries of same intent.
- Final source of truth remains server response.

### Security basics
- token storage in Keychain on iOS
- short-lived access tokens + refresh flow
- server-side validation of every write path

Example:
Run context: Split by platform: Keychain code in `iOS app target`; `updateStock` in `Vapor backend target`.
```swift
import Foundation
import Vapor
import Fluent

#if canImport(Security)
import Security
#endif

enum TokenStoreError: Error {
    case saveFailed
    case readFailed
}

struct KeychainTokenStore {
    func save(token: String) throws {
#if canImport(Security)
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "access_token",
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw TokenStoreError.saveFailed
        }
#else
        throw TokenStoreError.saveFailed
#endif
    }
}

struct SessionToken: Authenticatable {
    let userId: UUID
}

final class Stock: Model {
    static let schema = "stocks"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID

    init() {}
    init(id: UUID? = nil, userId: UUID) {
        self.id = id
        self.userId = userId
    }
}

func updateStock(req: Request) async throws -> HTTPStatus {
    let session = try req.auth.require(SessionToken.self)
    guard let stockId = req.parameters.get("stockId", as: UUID.self) else {
        throw Abort(.badRequest, reason: "Invalid stock id")
    }
    let stock = try await Stock.find(stockId, on: req.db)
    guard let stock else { throw Abort(.notFound) }
    guard stock.userId == session.userId else { throw Abort(.forbidden) }
    return .ok
}
```

What is actually happening:
- iOS stores tokens in Keychain, not plaintext files/user defaults.
- Every protected server write re-validates authenticated user ownership.
- Even if client is compromised, server still enforces authorization rules.

## 5) Day-by-Day Plan (8 Weeks)

Target pace: 60-90 minutes per day.

### Week 1: Swift Core (Types, Optionals, Error Handling)

1. Day 1: Set up study environment, verify `swift --version`, create a `notes.md` for learning logs.
2. Day 2: Practice `struct`, `class`, `enum`, and protocol basics with 3 small examples.
3. Day 3: Drill optionals (`if let`, `guard let`, nil-coalescing) with parsing exercises.
4. Day 4: Practice functions, computed properties, and immutability vs mutability.
5. Day 5: Implement custom error types and `throws`/`do-catch` in a small parser.
6. Day 6: Write XCTest cases for your parser and error paths.
7. Day 7: Review and refactor your exercises; write a one-page summary of weak points.

### Week 2: Swift Concurrency + Codable + SPM

1. Day 8: Learn `async/await` with a fake async API client.
2. Day 9: Use `async let` and task groups for parallel calls in a toy example.
3. Day 10: Learn `@MainActor`, `Sendable`, and actor basics; fix one deliberate race condition.
4. Day 11: Practice `Codable` decoding for nested JSON and optional fields.
5. Day 12: Add date decoding strategies and numeric formatting rules.
6. Day 13: Organize code as a Swift package target and write unit tests.
7. Day 14: Review all concurrency and decoding examples; write down recurring mistakes.

### Week 3: Vapor Basics + First CRUD Slice

1. Day 15: Read `configure.swift` and route registration flow in this repo.
2. Day 16: Create a new resource scaffold (DTO, controller, repository, service).
3. Day 17: Add Fluent model + migration for the new resource.
4. Day 18: Implement `POST` and `GET list` endpoints.
5. Day 19: Implement `GET by id`, `PUT`, and `DELETE`.
6. Day 20: Add request validation and consistent error responses.
7. Day 21: Manual endpoint testing with Bruno; fix all obvious edge cases.

### Week 4: Auth, Middleware, and Better Architecture

1. Day 22: Trace current auth flow (token issue, verification, protected groups).
2. Day 23: Protect new resource routes with JWT/session middleware.
3. Day 24: Enforce ownership checks for reads and writes.
4. Day 25: Refactor business logic out of controller into service where needed.
5. Day 26: Add repository tests and service tests for key rules.
6. Day 27: Add integration tests for auth + CRUD happy path.
7. Day 28: Review architecture decisions and document your dependency graph.

### Week 5: SwiftUI Fundamentals + Networking Layer

1. Day 29: Create iOS app shell with navigation and feature folders.
2. Day 30: Build a typed API client using `URLSession` and async/await.
3. Day 31: Implement login and token storage abstraction (prepare for Keychain).
4. Day 32: Build one list screen backed by real API data.
5. Day 33: Add loading, empty, and error states for that screen.
6. Day 34: Add create form flow with request validation feedback.
7. Day 35: Manual end-to-end run: login -> list -> create -> reload.

### Week 6: SwiftUI State + CRUD Completion

1. Day 36: Refactor state ownership (`@State`, `@StateObject`, `@EnvironmentObject`) intentionally.
2. Day 37: Add detail screen and edit flow for your resource.
3. Day 38: Add delete flow with confirmation and optimistic UI handling.
4. Day 39: Implement pull-to-refresh and task cancellation safety.
5. Day 40: Handle API error decoding into typed, user-friendly messages.
6. Day 41: Add UI tests or at least deterministic preview/test data states.
7. Day 42: End-to-end bug bash across happy and failure paths.

### Week 7: Integration Hardening

1. Day 43: Add pagination support to one list endpoint and corresponding UI.
2. Day 44: Add server-side filtering/sorting and wire it to app controls.
3. Day 45: Standardize API error schema across endpoints.
4. Day 46: Add request/response logging on one critical backend flow.
5. Day 47: Add retry policy for transient network failures in the app client.
6. Day 48: Add token refresh flow (or explicit re-login handling if refresh is not implemented).
7. Day 49: Validate OpenAPI contract and align iOS models with backend DTOs.

### Week 8: Production Readiness and Confidence

1. Day 50: Review migrations and data safety practices (idempotency, rollback awareness).
2. Day 51: Add smoke test checklist for backend startup and key endpoints.
3. Day 52: Add basic observability checklist (logs, failures, latency hotspots).
4. Day 53: Run full test suite and fix remaining flaky tests.
5. Day 54: Perform a full manual system test from iOS app to backend.
6. Day 55: Write a short architecture document for your final setup.
7. Day 56: Self-assessment against the "Definition of Done" section and plan next 4 weeks.

## 6) Practice Backlog for This Repository

Use this repo as your training ground. Complete these in order.

1. Add one new protected CRUD resource end to end (migration, model, repo, service, controller, tests).
2. Add request validation with clear client-facing errors.
3. Add pagination + filtering on one list endpoint.
4. Add integration tests for auth + CRUD happy path.
5. Generate/update OpenAPI and validate your iOS request/response models against it.
6. Build a SwiftUI feature that consumes that resource with full loading/error states.
7. Add token refresh flow and API retry logic in the app client.
8. Add logging around one critical business flow and verify logs during manual testing.

## 7) Minimum Tooling You Should Be Comfortable With

Backend:
- `swift build`
- `swift test`
- `swift run StockPlanBackend`
- DB migration commands for your environment

API testing:
- Bruno collection (manual endpoint verification)
- repeatable request sets for auth and protected routes

iOS:
- Xcode previews
- simulator debugging
- Instruments basics for memory/performance checks

## 8) Definition of Done: You Are Comfortable When...

You can say "yes" to all of these:
- I can add a new API resource without copying old code blindly.
- I can explain why a piece of state belongs in `@State` vs shared app state.
- I can debug a failing decode/encode issue quickly.
- I can secure an endpoint and prove unauthorized access is blocked.
- I can write tests for business logic and not only controller wiring.
- I can ship a simple SwiftUI feature that handles real-world API failures.

## 9) Common Gaps to Avoid

- Skipping Swift concurrency fundamentals and then fighting threading bugs.
- Putting business logic in controllers or views.
- Treating API errors as plain strings instead of typed models.
- Building UI only for happy paths.
- Writing no tests for parsing, validation, and service logic.

## 10) Recommended References

- Swift language: `https://docs.swift.org/swift-book/documentation/the-swift-programming-language/`
- Vapor docs: `https://docs.vapor.codes/`
- SwiftUI docs: `https://developer.apple.com/documentation/swiftui`
- URLSession + concurrency: Apple Developer Documentation
