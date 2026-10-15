import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Redis
import SQLKit
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

// MARK: - Client IP behind proxies

/// An unconfigured app, for building `Request`s. Reads the environment only.
private func withBareApp(_ test: (Application) async throws -> Void) async throws {
    try await DatabaseTestLock.withSharedAccess {
        let app = try await Application.make(.testing)
        do {
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

@Suite("Client IP behind trusted proxies")
struct ClientIPTests {
    private let trusted = ClientIP.defaultTrustedProxyCIDRs.split(separator: ",").compactMap { IPNetwork(String($0)) }

    @Test("A direct, untrusted peer is the client; its X-Forwarded-For is ignored")
    func untrustedPeerIgnoresHeader() {
        #expect(ClientIP.resolve(remoteAddress: "203.0.113.7", forwardedFor: ["198.51.100.1"], trusted: trusted) == "203.0.113.7")
    }

    @Test("Behind a trusted proxy, the rightmost untrusted hop is the client")
    func rightmostUntrustedHop() {
        let ip = ClientIP.resolve(
            remoteAddress: "10.42.0.5",
            forwardedFor: ["198.51.100.1, 203.0.113.9, 10.42.0.9"],
            trusted: trusted
        )
        #expect(ip == "203.0.113.9")
    }

    @Test("A spoofed leftmost hop cannot change the bucket")
    func spoofedLeftmostHop() {
        let honest = ClientIP.resolve(remoteAddress: "10.42.0.5", forwardedFor: ["203.0.113.9"], trusted: trusted)
        let spoofed = ClientIP.resolve(
            remoteAddress: "10.42.0.5", forwardedFor: ["1.2.3.4, 5.6.7.8", "203.0.113.9"], trusted: trusted
        )
        #expect(honest == "203.0.113.9")
        #expect(spoofed == honest)
    }

    @Test("With only internal hops, the peer is used rather than a spoofable header value")
    func allTrustedFallsBackToPeer() {
        let ip = ClientIP.resolve(remoteAddress: "10.42.0.5", forwardedFor: ["10.1.2.3, 192.168.1.1"], trusted: trusted)
        #expect(ip == "10.42.0.5")
        #expect(ClientIP.resolve(remoteAddress: "10.42.0.5", forwardedFor: [], trusted: trusted) == "10.42.0.5")
    }

    @Test("CIDR matching covers IPv4, IPv6 and IPv4-mapped IPv6")
    func cidrMatching() throws {
        let cgnat = try #require(IPNetwork("100.64.0.0/10"))
        #expect(try cgnat.contains(#require(IPAddressBytes("100.100.1.1"))))
        #expect(try !cgnat.contains(#require(IPAddressBytes("100.128.0.1"))))
        #expect(try #require(IPNetwork("10.0.0.0/8")).contains(#require(IPAddressBytes("::ffff:10.1.2.3"))))
        #expect(try #require(IPNetwork("fd00::/8")).contains(#require(IPAddressBytes("fd12::1"))))
        #expect(IPNetwork("10.0.0.0/33") == nil)
    }

    @Test("Two clients behind the proxy get separate rate-limit buckets; spoofing keeps yours")
    func rateLimitBuckets() async throws {
        try await withBareApp { app in
            func identifier(_ xff: String) throws -> String {
                let req = try Request(
                    application: app,
                    headers: ["X-Forwarded-For": xff],
                    remoteAddress: SocketAddress(ipAddress: "10.42.0.5", port: 443),
                    on: app.eventLoopGroup.next()
                )
                return RateLimitMiddleware.identifier(for: req)
            }
            let alice = try identifier("203.0.113.1")
            let bob = try identifier("203.0.113.2")
            let aliceSpoofing = try identifier("9.9.9.9, 203.0.113.1")
            #expect(alice == "203.0.113.1")
            #expect(alice != bob)
            #expect(aliceSpoofing == alice)
        }
    }
}

// MARK: - Log and payload hygiene

@Suite("Trust hygiene")
struct TrustHygieneTests {
    @Test("Sentry never sees a query string")
    func sentryStripsQuery() async throws {
        try await withBareApp { app in
            let req = Request(
                application: app,
                method: .GET,
                url: URI(string: "/v1/auth/oauth/callback?code=secret-code&email=a%40b.c"),
                on: app.eventLoopGroup.next()
            )
            let payload = SentryReporter.buildEventPayload(
                error: Abort(.internalServerError), request: req, status: .internalServerError,
                environment: "test", requestID: nil, userID: nil
            )
            let serialized = try String(
                data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8
            ) ?? ""
            #expect(!serialized.contains("secret-code"))
            #expect(!serialized.contains("query"))
            #expect((payload["extra"] as? [String: Any])?["path"] as? String == "/v1/auth/oauth/callback")
        }
    }

    @Test("OpenRouter requests deny data collection; other hosts get no provider block")
    func openRouterDeniesDataCollection() async throws {
        let reply = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#
        for (baseURL, expectsProvider) in [
            ("https://openrouter.ai/api/v1", true),
            ("https://api.openai.com/v1", false),
        ] {
            let stub = AnthropicStubHTTP([(.ok, reply)])
            try await stub.withRequest { req in
                let client = DefaultOpenAIChatClient(apiKey: "k", model: "m", baseURL: baseURL, maxTokens: 100)
                _ = try await client.chat(
                    messages: [OpenAIMessage(role: "user", content: "Hi")], tools: [], responseFormat: nil, on: req
                )
            }
            let body = try #require(stub.bodies.first)
            if expectsProvider {
                #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
            } else {
                #expect(body["provider"] == nil)
            }
        }

        // The Anthropic rung builds its own request and never carries it.
        let anthropic = AnthropicChatClient.makeRequest(
            messages: [OpenAIMessage(role: "user", content: "Hi")], tools: [], responseFormat: nil,
            model: "claude-haiku-5-5", maxTokens: 100, options: AnthropicMessagesOptions()
        )
        let raw = try String(bytes: JSONEncoder().encode(anthropic), encoding: .utf8) ?? ""
        #expect(!raw.contains("data_collection"))
        #expect(!raw.contains("temperature"))
    }

    @Test("The signup alert carries no email")
    func signupAlertHasNoEmail() async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                let recorder = DiscordRecorder()
                app.discord = recorder
                try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                    try req.content.encode(AuthRegisterRequest(
                        username: "alerted_user", password: "Password123!", confirmPassword: "Password123!",
                        email: "alerted@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
                    ))
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                })
                // The alert is fire-and-forget.
                for _ in 0 ..< 50 where recorder.messages.isEmpty {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(recorder.messages == ["🎉 New user registered (password)"])
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }
}

final class DiscordRecorder: DiscordWebhookService, @unchecked Sendable {
    private let lock = NIOLock()
    private var sent: [String] = []

    var messages: [String] {
        lock.withLock { sent }
    }

    func send(_ message: String, on _: Request) async throws {
        lock.withLock { sent.append(message) }
    }
}

// MARK: - AI consent

/// Mutates `AI_CONSENT_ENFORCED`, so every test runs exclusively.
@Suite("AI consent", .serialized, .databaseLocked)
struct AIConsentTests {
    private func withApp(enforced: Bool, grace: Bool = false, _ test: (Application) async throws -> Void) async throws {
        setenv("AI_CONSENT_ENFORCED", enforced ? "true" : "false", 1)
        setenv("AI_CONSENT_LEGACY_IOS_GRACE", grace ? "true" : "false", 1)
        defer {
            unsetenv("AI_CONSENT_ENFORCED")
            unsetenv("AI_CONSENT_LEGACY_IOS_GRACE")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(AuthRegisterRequest(
                username: "consent_\(id)", password: "Password123!", confirmPassword: "Password123!",
                email: "consent+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            ))
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func call(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String, headers: HTTPHeaders = [:]
    ) async throws -> (status: HTTPStatus, body: String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            for (name, value) in headers {
                req.headers.replaceOrAdd(name: name, value: value)
            }
        }, afterResponse: { res async in
            result = (res.status, res.body.string)
        })
        return result
    }

    @Test("GET, POST and DELETE /v1/users/ai-consent round-trip, with null spelled out")
    func consentEndpoints() async throws {
        try await withApp(enforced: false) { app in
            let auth = try await register(app, "endpoints")

            let initial = try await call(app, .GET, "v1/users/ai-consent", token: auth.token)
            #expect(initial.status == .ok)
            #expect(initial.body == #"{"consentedAt":null}"#)

            let granted = try await call(app, .POST, "v1/users/ai-consent", token: auth.token)
            #expect(granted.status == .ok)
            let grantedAt = try #require(
                JSONDecoder().decode(AIConsentResponse.self, from: Data(granted.body.utf8)).consentedAt
            )
            #expect(abs(grantedAt.timeIntervalSinceNow) < 60)
            #expect(granted.body.range(of: #"^\{"consentedAt":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"\}$"#, options: .regularExpression) != nil)

            // A repeat keeps the first timestamp.
            let again = try await call(app, .POST, "v1/users/ai-consent", token: auth.token)
            #expect(again.body == granted.body)
            #expect(try await call(app, .GET, "v1/users/ai-consent", token: auth.token).body == granted.body)

            let withdrawn = try await call(app, .DELETE, "v1/users/ai-consent", token: auth.token)
            #expect(withdrawn.status == .ok)
            #expect(withdrawn.body == #"{"consentedAt":null}"#)
            #expect(try await User.find(auth.userId, on: app.db)?.aiDataConsentAt == nil)
        }
    }

    @Test("Enforced: an AI route answers 403 AI_CONSENT_REQUIRED until the user consents")
    func enforcedBlocksUntilConsent() async throws {
        try await withApp(enforced: true) { app in
            let auth = try await register(app, "enforced")

            let blocked = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token)
            #expect(blocked.status == .forbidden)
            let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(blocked.body.utf8))
            #expect(envelope.reason == "AI_CONSENT_REQUIRED")
            #expect(envelope.code == "forbidden")

            _ = try await call(app, .POST, "v1/users/ai-consent", token: auth.token)
            let allowed = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token)
            #expect(!allowed.body.contains("AI_CONSENT_REQUIRED"))

            #expect(try await AIConsent.isAllowed(userId: auth.userId, on: app.db))
        }
    }

    private static let legacyIOS: HTTPHeaders = ["User-Agent": "Norviq/96 CFNetwork/1568.100.1 Darwin/24.0.0"]
    private static let currentIOS: HTTPHeaders = [
        "User-Agent": "Norviq/97 CFNetwork/1568.100.1 Darwin/24.0.0",
        "X-StockPlan-Client-Capabilities": "mfa-auth-v1, ai-consent-v1",
    ]
    private static let web: HTTPHeaders = ["User-Agent": "norviq-web/1.0 Go-http-client/1.1"]

    @Test("Legacy-iOS grace: an old iOS build without consent is let through and counted")
    func legacyGraceAllowsOldIOS() async throws {
        try await withApp(enforced: true, grace: true) { app in
            let auth = try await register(app, "legacy_ios")
            let before = PrometheusMetrics.shared.aiConsentLegacyGrace.load(ordering: .relaxed)
            let response = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token, headers: Self.legacyIOS)
            #expect(!response.body.contains("AI_CONSENT_REQUIRED"))
            #expect(PrometheusMetrics.shared.aiConsentLegacyGrace.load(ordering: .relaxed) > before)
        }
    }

    @Test("Legacy-iOS grace never covers clients that ship the sheet, web, or grace-off")
    func legacyGraceIsNarrow() async throws {
        try await withApp(enforced: true, grace: true) { app in
            let auth = try await register(app, "grace_narrow")
            for headers in [Self.currentIOS, Self.web, [:]] {
                let response = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token, headers: headers)
                #expect(response.status == .forbidden)
                #expect(response.body.contains("AI_CONSENT_REQUIRED"))
            }
            // Jobs and Telegram use the strict check: no request, no grace.
            #expect(try await AIConsent.isAllowed(userId: auth.userId, on: app.db) == false)
            let summary = await AIDailyTipJob().runOnce(app)
            #expect(summary.considered == 0)
        }
        try await withApp(enforced: true, grace: false) { app in
            let auth = try await register(app, "grace_off")
            let response = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token, headers: Self.legacyIOS)
            #expect(response.status == .forbidden)
        }
    }

    @Test("A consented user passes whatever the client")
    func consentedPassesEverywhere() async throws {
        try await withApp(enforced: true, grace: true) { app in
            let auth = try await register(app, "consented_all")
            _ = try await call(app, .POST, "v1/users/ai-consent", token: auth.token)
            for headers in [Self.currentIOS, Self.web, Self.legacyIOS] {
                let response = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token, headers: headers)
                #expect(!response.body.contains("AI_CONSENT_REQUIRED"))
            }
        }
    }

    @Test("Not enforced: nothing changes for a user who never consented")
    func notEnforcedIsANoOp() async throws {
        try await withApp(enforced: false) { app in
            let auth = try await register(app, "relaxed")
            let response = try await call(app, .GET, "v1/ai/insights/summary", token: auth.token)
            #expect(!response.body.contains("AI_CONSENT_REQUIRED"))
            #expect(try await AIConsent.isAllowed(userId: auth.userId, on: app.db))
        }
    }

    @Test("Daily tips skip Pro users without consent, and only while enforced")
    func dailyTipsSkipWithoutConsent() async throws {
        for enforced in [true, false] {
            try await withApp(enforced: enforced) { app in
                let auth = try await register(app, "tips_\(enforced)")
                try await Entitlement(userId: auth.userId, level: "pro").save(on: app.db)
                let preference = AIAssistantPreference(userId: auth.userId)
                preference.proactiveTipsEnabled = true
                try await preference.save(on: app.db)

                let summary = await AIDailyTipJob().runOnce(app)
                #expect(summary.skippedNoConsent == (enforced ? 1 : 0))
                #expect(summary.considered == (enforced ? 0 : 1))
            }
        }
    }

    @Test("Telegram gets a sentence pointing to the app, not an error code")
    func telegramConsentReply() {
        #expect(!MessagingService.aiConsentRequiredText.contains("AI_CONSENT_REQUIRED"))
        #expect(MessagingService.aiConsentRequiredText.contains("Norviq app"))
    }
}

// MARK: - Retention, migrations and rate limits

@Suite("Trust retention and robustness", .serialized)
struct TrustRetentionTests {
    private func withApp(redis: Bool = false, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                if redis, let url = Environment.get("REDIS_URL"), !url.isEmpty {
                    // configure() leaves Redis off under .testing.
                    app.redis.configuration = try RedisConfiguration(url: url)
                }
                try await configure(app)
                try await app.autoMigrate()
                if redis {
                    // RedisKit builds its pools on boot.
                    try await app.asyncBoot()
                }
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(AuthRegisterRequest(
                username: "keep_\(id)", password: "Password123!", confirmPassword: "Password123!",
                email: "keep+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            ))
        }, afterResponse: { res async throws in
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func tempFile() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("An expired export answers 410, and cleanup deletes the file with the row")
    func exportExpiry() async throws {
        try await withApp { app in
            let auth = try await register(app, "export")
            let path = try tempFile()
            let export = DataExport(
                userId: auth.userId, type: .portfolio, format: .json, status: .ready,
                filePath: path, expiresAt: Date().addingTimeInterval(-60)
            )
            try await export.save(on: app.db)
            let exportId = try export.requireID()

            try await app.testing().test(.GET, "v1/api/v3/export/file/\(auth.userId)/\(exportId).json", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .gone)
            })

            let deleted = try await DatabaseDataExportRepository().deleteExpired(before: Date(), on: app.db)
            #expect(deleted == 1)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(try await DataExport.find(exportId, on: app.db) == nil)
        }
    }

    @Test("Proposed AI actions older than 30 days are purged")
    func pendingActionsPurged() async throws {
        try await withApp { app in
            let auth = try await register(app, "actions")
            func action(_ status: String) async throws -> UUID {
                let action = AIPendingAction()
                action.userId = auth.userId
                action.toolName = "list_expenses"
                action.argumentsEncrypted = Data()
                action.summaryEncrypted = Data()
                action.status = status
                action.expiresAt = Date()
                try await action.save(on: app.db)
                return try action.requireID()
            }
            let old = try await action("executed")
            let recent = try await action("pending")
            guard let sql = app.db as? any SQLDatabase else { return }
            try await sql.raw("UPDATE ai_pending_actions SET created_at = now() - interval '31 days' WHERE id = \(bind: old)").run()

            await AIAssistantRetentionJob().runOnce(app)
            #expect(try await AIPendingAction.find(old, on: app.db) == nil)
            #expect(try await AIPendingAction.find(recent, on: app.db) != nil)
        }
    }

    @Test("The cascade migration can run twice")
    func cascadeMigrationIsRerunnable() async throws {
        try await withApp { app in
            try await CascadeUserOwnedRowsOnDelete().prepare(on: app.db)
            try await CascadeUserOwnedRowsOnDelete().prepare(on: app.db)
        }
    }

    @Test("Backfill marks verified only on a verified identity with the account's own email")
    func backfillVerifiesOnlyMatchingIdentities() async throws {
        try await withApp { app in
            func user(_ email: String) async throws -> UUID {
                let id = UUID()
                try await User(id: id, email: email, passwordHash: "x").create(on: app.db)
                return id
            }
            let matching = try await user("match@example.com")
            let relay = try await user("relay@example.com")
            let unverified = try await user("unverified@example.com")
            try await OAuthIdentity(userID: matching, provider: "google", providerUserID: "g1",
                                    email: "MATCH@example.com", emailVerified: true).create(on: app.db)
            try await OAuthIdentity(userID: relay, provider: "apple", providerUserID: "a1",
                                    email: "abc@privaterelay.appleid.com", emailVerified: true).create(on: app.db)
            try await OAuthIdentity(userID: unverified, provider: "x", providerUserID: "x1",
                                    email: "unverified@example.com", emailVerified: false).create(on: app.db)

            try await BackfillEmailVerifiedAtAndPasswordSetAt().prepare(on: app.db)
            #expect(try await User.find(matching, on: app.db)?.emailVerifiedAt != nil)
            #expect(try await User.find(relay, on: app.db)?.emailVerifiedAt == nil)
            #expect(try await User.find(unverified, on: app.db)?.emailVerifiedAt == nil)
        }
    }

    @Test("Email and password changes are capped at 5 attempts a minute per user")
    func credentialChangesAreRateLimited() async throws {
        try await withApp(redis: true) { app in
            guard app.redis.configuration != nil else {
                Issue.record("REDIS_URL not set: the rate-limit test needs a Redis")
                return
            }
            let auth = try await register(app, "ratelimit")
            var statuses: [HTTPStatus] = []
            for _ in 0 ..< 6 {
                try await app.testing().test(.PATCH, "v1/users/password", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: auth.token)
                    try req.content.encode(UpdatePasswordRequest(currentPassword: "Wrong123!", newPassword: "NewPassword123!"))
                }, afterResponse: { res async in
                    statuses.append(res.status)
                })
            }
            #expect(statuses.prefix(5).allSatisfy { $0 == .badRequest })
            #expect(statuses.last == .tooManyRequests)
        }
    }

    @Test("Proactive tips deny OpenRouter data collection; other hosts get no provider block")
    func tipsRequestDeniesDataCollection() throws {
        let openRouter = AIDailyTipJob.tipsRequest(model: "m", input: "i", baseURL: "https://openrouter.ai/api/v1")
        let openAI = AIDailyTipJob.tipsRequest(model: "m", input: "i", baseURL: "https://api.openai.com/v1")
        let encoded = try String(decoding: JSONEncoder().encode(openRouter), as: UTF8.self)
        #expect(encoded.contains(#""data_collection":"deny""#))
        #expect(try !String(decoding: JSONEncoder().encode(openAI), as: UTF8.self).contains("provider"))
    }
}
