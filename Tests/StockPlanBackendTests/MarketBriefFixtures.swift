import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

enum MarketBriefFixtures {
    static func response(
        date: String = "2026-10-08",
        slot: MarketBriefSlot = .morning,
        language: String = "en",
        degraded: Bool = false
    ) -> MarketBriefResponse {
        MarketBriefResponse(
            enabled: true,
            tradingDate: date,
            slot: slot,
            language: language,
            greeting: language == "en" ? "Good morning," : "Bom dia,",
            groups: [],
            items: [MarketBriefItem(kind: slot == .morning ? .highlight : .story, text: "Line for \(language).", tickers: [], sourceUrl: nil)],
            generatedAt: "2026-10-08T07:15:00Z",
            degraded: degraded
        )
    }

    /// Configured, migrated app inside the shared DB lock, the same shape as
    /// `MarketOwnershipRouteTests.withApp`.
    static func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }
}

struct StubIndexQuoteProvider: IndexQuoteProvider {
    let result: [IndexQuote]

    func quotes(symbols: [String], now _: Date, on _: Request) async -> [IndexQuote] {
        result.filter { symbols.contains($0.symbol) }
    }
}

/// Replies in order; records every message list it was sent.
final class ScriptedBriefChatClient: OpenAIChatClient, @unchecked Sendable {
    enum Reply {
        case content(String)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [[OpenAIMessage]] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var calls: [[OpenAIMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func chat(messages: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
        switch next(recording: messages) {
        case let .content(text): return OpenAIMessage(role: "assistant", content: text)
        case let .failure(error): throw error
        }
    }

    /// Synchronous so it may take the lock (NSLock is unavailable in async code).
    private func next(recording messages: [OpenAIMessage]) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(messages)
        return replies.isEmpty ? Reply.failure(Abort(.badGateway)) : replies.removeFirst()
    }
}

struct StubEarningsService: EarningsService {
    var items: [EarningsItemResponse] = []

    func getCalendar(query _: EarningsQueryRequest, on _: Request) async throws -> [EarningsItemResponse] {
        items
    }
}

extension MarketBriefFixtures {
    /// A valid two-language draft with `count` number-free items of `kind`.
    static func draftJSON(kind: String = "highlight", count: Int = 5) -> String {
        let items = (1 ... max(count, 1)).map { index in
            #"{"kind":"\#(kind)","text":"Line \#(index) of the brief.","tickers":[],"sourceUrl":null}"#
        }.joined(separator: ",")
        return #"{"en":{"greeting":"Good morning,","items":[\#(items)]},"pt-PT":{"greeting":"Bom dia,","items":[\#(items)]}}"#
    }

    /// A bare app (no configure, no DB) and a request on it, for code that
    /// only needs `req.logger` and `req.client`.
    static func withRequest(_ body: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(Request(application: app, on: app.eventLoopGroup.next()))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

final class StubMarketBriefGenerator: MarketBriefGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func generate(_ due: MarketBriefSchedule.Due, on _: Request) async throws -> GeneratedMarketBrief {
        recordCall()
        if let error { throw error }
        return GeneratedMarketBrief(
            responses: MarketBriefLanguage.allCases.map {
                MarketBriefFixtures.response(date: due.tradingDate, slot: due.slot, language: $0.rawValue)
            },
            model: "stub"
        )
    }

    /// Synchronous so it may take the lock (NSLock is unavailable in async code).
    private func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
