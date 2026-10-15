import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Replies in order. Locking happens in a synchronous helper (NSLock is
/// unavailable in async code under Swift 6).
final class ScriptedTerminalChatClient: OpenAIChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, any Error>]

    init(_ replies: [Result<String, any Error>]) {
        self.replies = replies
    }

    func chat(messages _: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
        try OpenAIMessage(role: "assistant", content: next().get())
    }

    private func next() -> Result<String, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? .failure(Abort(.badGateway)) : replies.removeFirst()
    }
}

/// Records every message list it is sent. Locking in sync helpers only.
final class CapturingTerminalChatClient: OpenAIChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[OpenAIMessage]] = []
    let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func chat(messages: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
        record(messages)
        return OpenAIMessage(role: "assistant", content: reply)
    }

    private func record(_ messages: [OpenAIMessage]) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(messages)
    }

    func userMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured.compactMap { $0.last(where: { $0.role == "user" })?.content }
    }
}

@Suite("Terminal AI advisor", .serialized)
struct TerminalAIAdvisorTests {
    private let factsJSON = #"""
    Sure:
    ```json
    {"sharesOutstanding": 10600000000, "currentSharePrice": 221.3, "currency": "usd", "asOf": "2026-09-30",
     "sources": ["https://www.sec.gov/amzn-10q", "http://insecure.example"]}
    ```
    """#

    @Test("Share facts parse from a fenced reply; only https sources survive")
    func parsesFacts() throws {
        let facts = try TerminalAIAdvisor.parseShareFacts(factsJSON, ticker: "AMZN")
        #expect(facts.sharesOutstanding == 10_600_000_000)
        #expect(facts.currentSharePrice == 221.3)
        #expect(facts.currency == "USD")
        #expect(facts.sources == ["https://www.sec.gov/amzn-10q"])
    }

    @Test("Numbers without an https source, or non-positive numbers, are unusable")
    func rejectsUnsourcedOrBad() {
        let unsourced = #"{"sharesOutstanding": 1000, "currentSharePrice": 10, "sources": []}"#
        let negative = #"{"sharesOutstanding": -5, "currentSharePrice": 0, "sources": ["https://x.example"]}"#
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts(unsourced, ticker: "X") }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts(negative, ticker: "X") }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts("no json", ticker: "X") }
    }

    @Test("Scenario parses; zero share count or empty rationale is unusable")
    func parsesScenario() throws {
        let good = #"{"terminalShareCount": 1750000000, "terminalMarketCap": 150000000000, "rationale": "Consensus growth.", "sources": ["https://a.example"]}"#
        let scenario = try TerminalAIAdvisor.parseScenario(good, ticker: "SOFI", horizonYears: 10)
        #expect(scenario.terminalShareCount == 1_750_000_000)
        #expect(scenario.horizonYears == 10)
        let zero = #"{"terminalShareCount": 0, "terminalMarketCap": 1, "rationale": "x", "sources": ["https://a.example"]}"#
        let empty = #"{"terminalShareCount": 1, "terminalMarketCap": 1, "rationale": " ", "sources": ["https://a.example"]}"#
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseScenario(zero, ticker: "X", horizonYears: 10) }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseScenario(empty, ticker: "X", horizonYears: 10) }
    }

    // MARK: - Endpoint

    /// Exclusive lock: BYPASS_BILLING is process-wide (same pattern as MCPTokenAuthTests).
    private func withApp(pro: Bool, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let previous = getenv("BYPASS_BILLING").map { String(cString: $0) }
            setenv("BYPASS_BILLING", pro ? "true" : "false", 1)
            defer {
                if let previous {
                    setenv("BYPASS_BILLING", previous, 1)
                } else {
                    unsetenv("BYPASS_BILLING")
                }
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
    }

    private func post(_ app: Application, token: String, _ check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "v1/terminal-positions/ai/share-facts", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(ShareFactsRequest(ticker: "amzn"), as: .json)
        }, afterResponse: check)
    }

    @Test("Free users get 403 upgrade_required")
    func freeIsUpgrade() async throws {
        try await withApp(pro: false) { app in
            app.terminalAIClient = ScriptedTerminalChatClient([.success(factsJSON)])
            let user = try await TerminalFixtures.registerUser(app: app)
            // Registration starts a Pro trial; end it so the user is really free.
            let record = try await User.find(user.userId, on: app.db)
            record?.trialTier = nil
            try await record?.save(on: app.db)
            try await post(app, token: user.token) { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("upgrade_required"))
            }
        }
    }

    @Test("Pro gets a sourced suggestion; no client or a failing client is 503")
    func proPaths() async throws {
        try await withApp(pro: true) { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            app.terminalAIClient = ScriptedTerminalChatClient([.success(factsJSON)])
            try await post(app, token: user.token) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(ShareFactsSuggestion.self)
                #expect(body.ticker == "AMZN")
                #expect(body.sharesOutstanding == 10_600_000_000)
            }
            app.terminalAIClient = ScriptedTerminalChatClient([.failure(Abort(.paymentRequired))])
            try await post(app, token: user.token) { res in
                #expect(res.status == .serviceUnavailable)
            }
            app.terminalAIClient = nil
            try await post(app, token: user.token) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    private let scenarioJSON = #"{"terminalShareCount": 1750000000, "terminalMarketCap": 150000000000, "rationale": "Consensus growth.", "sources": ["https://a.example"]}"#

    private func postScenario(_ app: Application, token: String, horizon: Int?, _ check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "v1/terminal-positions/ai/scenario", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(TerminalScenarioSuggestionRequest(ticker: "sofi", horizonYears: horizon), as: .json)
        }, afterResponse: check)
    }

    @Test("Scenario endpoint returns the suggestion and clamps horizonYears to 1...30")
    func scenarioEndpointClampsHorizon() async throws {
        try await withApp(pro: true) { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            app.terminalAIClient = ScriptedTerminalChatClient([.success(scenarioJSON), .success(scenarioJSON), .success(scenarioJSON)])
            try await postScenario(app, token: user.token, horizon: 5) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(TerminalScenarioSuggestion.self)
                #expect(body.ticker == "SOFI")
                #expect(body.terminalShareCount == 1_750_000_000)
                #expect(body.terminalMarketCap == 150_000_000_000)
                #expect(body.horizonYears == 5)
            }
            try await postScenario(app, token: user.token, horizon: 99) { res in
                let body = try res.content.decode(TerminalScenarioSuggestion.self)
                #expect(body.horizonYears == 30)
            }
            try await postScenario(app, token: user.token, horizon: 0) { res in
                let body = try res.content.decode(TerminalScenarioSuggestion.self)
                #expect(body.horizonYears == 1)
            }
        }
    }

    @Test("Scenario and share-facts prompts name the user's currency, not the reporting currency")
    func promptsNameUserCurrency() async throws {
        try await withApp(pro: true) { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            try await PortfolioList.query(on: app.db).filter(\PortfolioList.$userId == user.userId).delete()
            try await PortfolioList(userId: user.userId, name: "Euro", isDefault: true, baseCurrency: "EUR").save(on: app.db)
            let client = CapturingTerminalChatClient(reply: scenarioJSON)
            app.terminalAIClient = client
            try await postScenario(app, token: user.token, horizon: 10) { res in
                #expect(res.status == .ok)
            }
            let users = client.userMessages()
            #expect(users.count == 1)
            #expect(users.first?.contains("EUR") == true)
        }
    }

    @Test("Live client is built for OpenRouter, or for another provider only with TERMINAL_AI_MODEL")
    func liveClientEligibility() {
        let url = "https://example.invalid/v1"
        #expect(TerminalAIAdvisor.liveClient(provider: .openRouter, apiKey: "k", baseURL: url, configuredModel: nil) != nil)
        #expect(TerminalAIAdvisor.liveClient(provider: .openAI, apiKey: "k", baseURL: url, configuredModel: nil) == nil)
        #expect(TerminalAIAdvisor.liveClient(provider: .openAI, apiKey: "k", baseURL: url, configuredModel: "  ") == nil)
        #expect(TerminalAIAdvisor.liveClient(provider: .openAI, apiKey: "k", baseURL: url, configuredModel: "gpt-x") != nil)
        #expect(TerminalAIAdvisor.liveClient(provider: .openRouter, apiKey: "", baseURL: url, configuredModel: nil) == nil)
        #expect(TerminalAIAdvisor.unavailableReason(provider: .custom, apiKey: "k", baseURL: url, configuredModel: nil)?.contains("TERMINAL_AI_MODEL") == true)
    }

    @Test("Summing never overflows to infinity")
    func finiteSumStaysFinite() {
        let sum = TerminalPositionsService.finiteSum([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, 5])
        #expect(sum.isFinite)
        #expect(TerminalPositionsService.finiteSum([1, .infinity, .nan, 2]) == 3)
    }
}
