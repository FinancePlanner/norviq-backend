import _CryptoExtras
import Fluent
import Foundation
import JWTKit
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Stands in for api.enablebanking.com: answers by method + path from a
/// mutable route table and records every request.
final class EnableBankingStubHTTP: @unchecked Sendable {
    private let lock = NIOLock()
    private var routes: [String: [(HTTPStatus, String)]] = [:]
    private var recorded: [ClientRequest] = []

    /// Queues replies for `"GET /aspsps"`-style keys; the last one repeats.
    func on(_ key: String, _ replies: (HTTPStatus, String)...) {
        lock.withLock { routes[key] = replies }
    }

    func reply(to request: ClientRequest) -> (HTTPStatus, String) {
        lock.withLock {
            recorded.append(request)
            let key = "\(request.method.rawValue) \(request.url.path)"
            guard var queue = routes[key], !queue.isEmpty else {
                return (.notFound, #"{"error":"NOT_STUBBED"}"#)
            }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[key] = queue
            return next
        }
    }

    func requests(_ key: String) -> [ClientRequest] {
        lock.withLock { recorded.filter { key == "\($0.method.rawValue) \($0.url.path)" } }
    }

    func json(_ request: ClientRequest) -> [String: Any] {
        guard let buffer = request.body,
              let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    struct Client: Vapor.Client {
        let stub: EnableBankingStubHTTP
        let eventLoop: any EventLoop

        func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
            let (status, body) = stub.reply(to: request)
            var headers = HTTPHeaders()
            headers.contentType = .json
            return eventLoop.makeSucceededFuture(ClientResponse(status: status, headers: headers, body: ByteBuffer(string: body)))
        }

        func delegating(to eventLoop: any EventLoop) -> any Vapor.Client {
            Client(stub: stub, eventLoop: eventLoop)
        }
    }
}

@Suite("Enable Banking Provider", .serialized)
struct EnableBankingProviderTests {
    static let appRedirect = "norviqa://oauth/bank-callback"

    // MARK: - Auth

    @Test("Request JWT is RS256 with the app id as kid and the documented claims")
    func tokenShape() async throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let client = EnableBankingClient(config: Self.config(pem: privateKey.pemRepresentation))
        let now = Date()
        let token = try await client.makeToken(now: now)

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try Self.decodeSegment(parts[0])
        let claims = try Self.decodeSegment(parts[1])
        #expect(header["alg"] as? String == "RS256")
        #expect(header["typ"] as? String == "JWT")
        #expect(header["kid"] as? String == "app-123")
        #expect(claims["iss"] as? String == "enablebanking.com")
        #expect(claims["aud"] as? String == "api.enablebanking.com")
        let iat = try #require(claims["iat"] as? Double)
        let exp = try #require(claims["exp"] as? Double)
        #expect(exp > iat)
        #expect(exp - iat <= 86400)

        let keys = JWTKeyCollection()
        try await keys.add(rsa: Insecure.RSA.PublicKey(backing: privateKey.publicKey), digestAlgorithm: .sha256, kid: JWKIdentifier(string: "app-123"))
        _ = try await keys.verify(token, as: VerifiedClaims.self)
    }

    // MARK: - Transactions

    @Test("Pagination continues through an empty page until the key is null")
    func paginationFollowsContinuationKey() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on(
            "GET /accounts/uid-1/transactions",
            (.ok, Self.page([Self.tx(ref: "r1")], key: "k1")),
            (.ok, Self.page([], key: "k2")),
            (.ok, Self.page([Self.tx(ref: "r2")], key: nil))
        )
        try await withApp(stub: stub) { app, provider in
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let transactions = try await provider.client.transactions(accountUID: "uid-1", dateFrom: nil, on: req)
            #expect(transactions.map(\.entryReference) == ["r1", "r2"])

            let calls = stub.requests("GET /accounts/uid-1/transactions")
            #expect(calls.count == 3)
            #expect(calls[0].url.query?.contains("strategy=longest") == true)
            #expect(calls[1].url.query?.contains("continuation_key=k1") == true)
            #expect(calls[2].url.query?.contains("continuation_key=k2") == true)
        }
    }

    // MARK: - Link flow

    @Test("Hosted link caps consent at the bank's maximum and stores the flow")
    func hostedLinkUsesBankConsentLimit() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on("GET /aspsps", (.ok, Self.aspsps(maxValidity: 90 * 86400)))
        stub.on("POST /auth", (.ok, #"{"url":"https://tilisy.example/auth/abc","authorization_id":"auth-1"}"#))
        try await withApp(stub: stub) { app, provider in
            let userId = try await Self.makeUser(app, email: "eb-link@example.com")
            let req = Request(application: app, on: app.eventLoopGroup.next())

            let session = try await provider.createHostedLink(
                userId: userId,
                institutionId: "PT:Banco Teste",
                redirectURI: Self.appRedirect,
                on: req
            )
            #expect(session.provider == .enablebanking)
            #expect(session.hostedURL == "https://tilisy.example/auth/abc")

            let body = try stub.json(#require(stub.requests("POST /auth").first))
            #expect(body["redirect_url"] as? String == "https://api.example.test/v1/banks/enablebanking/callback")
            #expect(body["psu_type"] as? String == "personal")
            #expect((body["aspsp"] as? [String: Any])?["country"] as? String == "PT")
            let validUntilRaw = try #require((body["access"] as? [String: Any])?["valid_until"] as? String)
            let validUntil = try #require(EnableBankingProvider.parseTimestamp(validUntilRaw))
            #expect(abs(validUntil.timeIntervalSinceNow - 90 * 86400) < 120)

            let flow = try #require(try await BankLinkFlow.query(on: app.db).first())
            #expect(flow.provider == "enablebanking")
            #expect(flow.requisitionId == "auth-1")
            #expect(flow.reference == body["state"] as? String)
        }
    }

    @Test("Callback creates the connection, backfills, and is replay-safe")
    func callbackCreatesConnectionAndBackfills() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on("POST /sessions", (.ok, Self.session(id: "session-1", uid: "uid-1")))
        stub.on("GET /accounts/uid-1/transactions", (.ok, Self.page([
            Self.tx(ref: "r-coffee", amount: "4.50", indicator: "DBIT", creditor: "Cafe Lisboa", mcc: "5814"),
            Self.tx(ref: "r-salary", amount: "2000.00", indicator: "CRDT", debtor: "ACME Lda"),
            Self.tx(ref: nil, amount: "12.00", indicator: "DBIT", status: "PDNG", creditor: "Uber"),
            Self.tx(ref: "r-cancelled", amount: "9.99", indicator: "DBIT", status: "CNCL", creditor: "Shop"),
        ], key: nil)))
        try await withApp(stub: stub) { app, _ in
            let userId = try await Self.makeUser(app, email: "eb-callback@example.com")
            try await Self.makeFlow(app, userId: userId, state: "state-1")

            for _ in 0 ..< 2 {
                try await app.testing().test(.GET, "v1/banks/enablebanking/callback?state=state-1&code=code-1") { res async in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "\(Self.appRedirect)?bank=connected")
                }
            }
            #expect(stub.requests("POST /sessions").count == 1)

            let connections = try await BankConnection.query(on: app.db).all()
            #expect(connections.count == 1)
            let connection = try #require(connections.first)
            #expect(connection.providerItemId == "session-1")
            #expect(connection.institutionName == "Banco Teste")
            #expect(connection.status == BankConnectionStatus.active.rawValue)

            let account = try #require(try await BankAccount.query(on: app.db).first())
            #expect(account.providerAccountId == "uid-1")
            #expect(account.identificationHash == "hash-1")
            #expect(account.mask == "1234")

            let rows = try await BankTransaction.query(on: app.db).all()
            #expect(rows.count == 3)
            let coffee = try #require(rows.first { $0.providerTxId == "r-coffee" })
            #expect(coffee.amount == -4.5)
            #expect(coffee.merchant == "Cafe Lisboa")
            #expect(coffee.providerCategory == "5814")
            let salary = try #require(rows.first { $0.providerTxId == "r-salary" })
            #expect(salary.amount == 2000)
            #expect(salary.merchant == "ACME Lda")
            #expect(rows.contains { $0.pending && $0.merchant == "Uber" })
        }
    }

    @Test("Bank cancellation redirects back with the error")
    func callbackForwardsBankError() async throws {
        let stub = EnableBankingStubHTTP()
        try await withApp(stub: stub) { app, _ in
            let userId = try await Self.makeUser(app, email: "eb-cancel@example.com")
            try await Self.makeFlow(app, userId: userId, state: "state-x")
            try await app.testing().test(.GET, "v1/banks/enablebanking/callback?state=state-x&error=access_denied") { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "\(Self.appRedirect)?bank=error&error=access_denied")
            }
            #expect(stub.requests("POST /sessions").isEmpty)
        }
    }

    @Test("Re-consent reuses the connection and re-points accounts by identification hash")
    func reconsentReusesConnection() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on(
            "POST /sessions",
            (.ok, Self.session(id: "session-1", uid: "uid-1")),
            (.ok, Self.session(id: "session-2", uid: "uid-2"))
        )
        let booked = Self.page([Self.tx(ref: "r-1", amount: "10.00", indicator: "DBIT", creditor: "Pingo Doce")], key: nil)
        stub.on("GET /accounts/uid-1/transactions", (.ok, booked))
        stub.on("GET /accounts/uid-2/transactions", (.ok, booked))
        try await withApp(stub: stub) { app, _ in
            let userId = try await Self.makeUser(app, email: "eb-reconsent@example.com")
            try await Self.makeFlow(app, userId: userId, state: "state-1")
            try await app.testing().test(.GET, "v1/banks/enablebanking/callback?state=state-1&code=c1") { _ async in }

            let connection = try #require(try await BankConnection.query(on: app.db).first())
            connection.status = BankConnectionStatus.reauthRequired.rawValue
            try await connection.save(on: app.db)

            try await Self.makeFlow(app, userId: userId, state: "state-2")
            try await app.testing().test(.GET, "v1/banks/enablebanking/callback?state=state-2&code=c2") { res async in
                #expect(res.headers.first(name: .location) == "\(Self.appRedirect)?bank=connected")
            }

            let connections = try await BankConnection.query(on: app.db).all()
            #expect(connections.count == 1)
            #expect(connections.first?.providerItemId == "session-2")
            #expect(connections.first?.status == BankConnectionStatus.active.rawValue)
            let accounts = try await BankAccount.query(on: app.db).all()
            #expect(accounts.map(\.providerAccountId) == ["uid-2"])
            #expect(try await BankTransaction.query(on: app.db).count() == 1)
        }
    }

    // MARK: - Sync

    @Test("Expired session flips the connection to reauth_required")
    func expiredSessionRequiresReauth() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on("GET /accounts/uid-1/transactions", (.unauthorized, #"{"code":401,"error":"EXPIRED_SESSION","message":"Session expired"}"#))
        try await withApp(stub: stub) { app, provider in
            let userId = try await Self.makeUser(app, email: "eb-expired@example.com")
            let connection = try await Self.makeConnection(app, userId: userId)
            let req = Request(application: app, on: app.eventLoopGroup.next())

            await #expect(throws: (any Error).self) {
                _ = try await provider.sync(connection: connection, on: req)
            }
            let reloaded = try #require(try await BankConnection.find(connection.id, on: app.db))
            #expect(reloaded.status == BankConnectionStatus.reauthRequired.rawValue)
            #expect(reloaded.lastSyncStatus == "consent_revoked")
        }
    }

    @Test("Un-reviewed pending rows are rebuilt each sync; booked rows are not duplicated")
    func pendingSuggestionsAreReplaced() async throws {
        let stub = EnableBankingStubHTTP()
        stub.on(
            "GET /accounts/uid-1/transactions",
            (.ok, Self.page([Self.tx(ref: nil, amount: "7.00", indicator: "DBIT", status: "PDNG", date: "2026-10-18", creditor: "Bolt")], key: nil)),
            (.ok, Self.page([Self.tx(ref: "r-bolt", amount: "7.00", indicator: "DBIT", date: "2026-10-19", creditor: "Bolt")], key: nil))
        )
        try await withApp(stub: stub) { app, provider in
            let userId = try await Self.makeUser(app, email: "eb-pending@example.com")
            let connection = try await Self.makeConnection(app, userId: userId)
            let req = Request(application: app, on: app.eventLoopGroup.next())

            _ = try await provider.sync(connection: connection, on: req)
            #expect(try await BankTransaction.query(on: app.db).filter(\.$pending == true).count() == 1)

            // Second sync covers the whole history again (no last sync yet).
            connection.lastSyncedAt = nil
            let second = try await provider.sync(connection: connection, on: req)
            #expect(second.removed == 1)
            let rows = try await BankTransaction.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect(rows.first?.providerTxId == "r-bolt")
            #expect(rows.first?.pending == false)
        }
    }

    // MARK: - Redirect allowlist

    @Test("Hosted-link redirect URIs must be allow-listed exactly")
    func redirectAllowlist() throws {
        let list = "norviqa://oauth/bank-callback, https://www.norviq.org/settings/banks"
        try BankController.validateRedirectURI("norviqa://oauth/bank-callback", allowList: list)
        try BankController.validateRedirectURI("https://www.norviq.org/settings/banks", allowList: list)
        #expect(throws: (any Error).self) {
            try BankController.validateRedirectURI("https://evil.example/settings/banks", allowList: list)
        }
        #expect(throws: (any Error).self) {
            try BankController.validateRedirectURI("norviqa://oauth/bank-callback", allowList: nil)
        }
    }

    // MARK: - Fixtures

    private struct VerifiedClaims: JWTPayload {
        let exp: ExpirationClaim
        func verify(using _: some JWTAlgorithm) async throws {
            try exp.verifyNotExpired()
        }
    }

    private static func config(pem: String = "unused") -> EnableBankingConfiguration {
        EnableBankingConfiguration(
            applicationID: "app-123",
            privateKeyPEM: pem,
            baseURL: "https://eb.example.test",
            redirectURL: "https://api.example.test/v1/banks/enablebanking/callback"
        )
    }

    private func withApp(stub: EnableBankingStubHTTP, _ test: (Application, EnableBankingProvider) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                let pem = try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
                let provider = EnableBankingProvider(client: EnableBankingClient(config: Self.config(pem: pem)))
                app.bankProviderRegistry = BankProviderRegistry(providers: [provider])
                app.clients.use { app in EnableBankingStubHTTP.Client(stub: stub, eventLoop: app.eventLoopGroup.next()) }
                try await test(app, provider)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private static func makeUser(_ app: Application, email: String) async throws -> UUID {
        let user = User(email: email, passwordHash: "hash")
        try await user.save(on: app.db)
        return try #require(user.id)
    }

    private static func makeFlow(_ app: Application, userId: UUID, state: String) async throws {
        try await BankLinkFlow(
            userId: userId,
            provider: BankProviderKind.enablebanking.rawValue,
            reference: state,
            requisitionId: "auth-\(state)",
            institutionId: "PT:Banco Teste",
            appRedirectURI: appRedirect,
            expiresAt: Date().addingTimeInterval(600)
        ).save(on: app.db)
    }

    private static func makeConnection(_ app: Application, userId: UUID) async throws -> BankConnection {
        let connection = BankConnection(
            userId: userId,
            provider: BankProviderKind.enablebanking.rawValue,
            institutionId: "PT:Banco Teste",
            institutionName: "Banco Teste",
            providerItemId: "session-1",
            status: BankConnectionStatus.active.rawValue,
            consentExpiresAt: Date().addingTimeInterval(30 * 86400)
        )
        try await connection.save(on: app.db)
        let account = try BankAccount(connectionId: #require(connection.id), providerAccountId: "uid-1", name: "Conta")
        account.identificationHash = "hash-1"
        try await account.save(on: app.db)
        return connection
    }

    private static func decodeSegment(_ segment: String) throws -> [String: Any] {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try #require(Data(base64Encoded: base64))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func aspsps(maxValidity: Int) -> String {
        #"{"aspsps":[{"name":"Banco Teste","country":"PT","logo":"https://eb.example.test/logo.png","bic":"BTESPTPL","beta":true,"maximum_consent_validity":\#(maxValidity)}]}"#
    }

    private static func session(id: String, uid: String) -> String {
        #"{"session_id":"\#(id)","accounts":[{"uid":"\#(uid)","identification_hash":"hash-1","name":"Conta Ordem","currency":"EUR","cash_account_type":"CACC","account_id":{"iban":"PT50000000000000000001234"}}],"aspsp":{"name":"Banco Teste","country":"PT"},"psu_type":"personal","access":{"valid_until":"2027-04-18T10:00:00.000000+00:00"}}"#
    }

    private static func page(_ transactions: [String], key: String?) -> String {
        let continuation = key.map { "\"\($0)\"" } ?? "null"
        return #"{"transactions":[\#(transactions.joined(separator: ","))],"continuation_key":\#(continuation)}"#
    }

    private static func tx(
        ref: String?,
        amount: String = "1.00",
        indicator: String = "DBIT",
        status: String = "BOOK",
        date: String = "2026-10-18",
        creditor: String? = nil,
        debtor: String? = nil,
        mcc: String? = nil
    ) -> String {
        var fields = [
            #""transaction_amount":{"amount":"\#(amount)","currency":"EUR"}"#,
            #""credit_debit_indicator":"\#(indicator)""#,
            #""status":"\#(status)""#,
            #""remittance_information":["Compra \#(creditor ?? debtor ?? "")"]"#,
        ]
        fields.append(status == "PDNG" ? #""transaction_date":"\#(date)""# : #""booking_date":"\#(date)""#)
        if let ref {
            fields.append(#""entry_reference":"\#(ref)""#)
        }
        if let creditor {
            fields.append(#""creditor":{"name":"\#(creditor)"}"#)
        }
        if let debtor {
            fields.append(#""debtor":{"name":"\#(debtor)"}"#)
        }
        if let mcc {
            fields.append(#""merchant_category_code":"\#(mcc)""#)
        }
        return "{\(fields.joined(separator: ","))}"
    }
}
