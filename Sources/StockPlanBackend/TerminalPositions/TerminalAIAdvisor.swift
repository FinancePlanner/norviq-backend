import Foundation
import StockPlanShared
import Vapor

/// AI suggestions for terminal position sizing. One web-search chat call per
/// suggestion, strict JSON, validated before it reaches the user. It never
/// writes: the user accepts a suggestion in the UI, which then PATCHes.
///
/// No sampling parameters are sent (Haiku 5.5 rejects them), and there is no
/// fallback without web search — a guessed share count is worse than none.
struct TerminalAIAdvisor: Sendable {
    /// OpenRouter's `:online` slug turns on web search.
    static let defaultModel = "anthropic/claude-haiku-4.5:online"
    static let defaultHorizonYears = 10

    let client: any OpenAIChatClient

    static func liveClient() -> (any OpenAIChatClient)? {
        let config = AIProviderConfiguration.load()
        guard !config.apiKey.isEmpty, !config.baseURL.isEmpty else { return nil }
        let configured = Environment.get("TERMINAL_AI_MODEL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DefaultOpenAIChatClient(
            apiKey: config.apiKey,
            model: configured.isEmpty ? defaultModel : configured,
            baseURL: config.baseURL,
            maxTokens: 1200,
            timeout: .seconds(60)
        )
    }

    static let shareFactsPrompt = """
    You look up public company share data with web search. Reply with only a JSON object:
    {"sharesOutstanding": number|null, "currentSharePrice": number|null, "currency": "ISO code"|null, \
    "asOf": "YYYY-MM-DD"|null, "sources": ["https://..."]}
    sharesOutstanding is the latest total shares outstanding from the most recent filing (10-Q, 10-K, \
    or the exchange/regulator equivalent), as a plain number, not in millions. currentSharePrice is the \
    latest price. Every number must come from a source you list; if you cannot find one, use null. \
    Never estimate.
    """

    static let scenarioPrompt = """
    You help an investor sketch ONE terminal scenario for a stock with web search. Reply with only a JSON object:
    {"terminalShareCount": number, "terminalMarketCap": number, "rationale": string, "sources": ["https://..."]}
    terminalShareCount is the share count you expect at the horizon given the dilution or buyback trend in \
    filings. terminalMarketCap is a market cap at the horizon grounded in published analyst ranges or the \
    company's historical growth, in the company's reporting currency, as a plain number. rationale is 1-3 \
    sentences naming what the numbers rest on. This is an assumption to be edited by the user, not a forecast \
    or advice.
    """

    func shareFacts(ticker: String, on req: Request) async throws -> ShareFactsSuggestion {
        let content = try await ask(system: Self.shareFactsPrompt, user: "Ticker: \(ticker)", on: req)
        return try Self.parseShareFacts(content, ticker: ticker)
    }

    func scenario(ticker: String, horizonYears: Int?, on req: Request) async throws -> TerminalScenarioSuggestion {
        let horizon = min(max(horizonYears ?? Self.defaultHorizonYears, 1), 30)
        let content = try await ask(
            system: Self.scenarioPrompt,
            user: "Ticker: \(ticker). Horizon: \(horizon) years.",
            on: req
        )
        return try Self.parseScenario(content, ticker: ticker, horizonYears: horizon)
    }

    private func ask(system: String, user: String, on req: Request) async throws -> String {
        do {
            let reply = try await client.chat(
                messages: [OpenAIMessage(role: "system", content: system), OpenAIMessage(role: "user", content: user)],
                tools: [],
                responseFormat: "json_object",
                on: req
            )
            return reply.content ?? ""
        } catch {
            req.logger.warning("terminal_ai_failed", metadata: ["error": .string(String(describing: error))])
            throw Abort(.serviceUnavailable, reason: "AI lookup unavailable. Try again later or enter the numbers yourself.")
        }
    }

    // MARK: - Parsing

    static let unusable = Abort(
        .unprocessableEntity,
        reason: "The AI answer had no usable, sourced numbers. Try again or enter them yourself."
    )

    static func parseShareFacts(_ content: String, ticker: String) throws -> ShareFactsSuggestion {
        struct Wire: Decodable {
            let sharesOutstanding: Double?
            let currentSharePrice: Double?
            let currency: String?
            let asOf: String?
            let sources: [String]?
        }
        let wire = try decodeObject(Wire.self, from: content)
        if let shares = wire.sharesOutstanding, !(shares.isFinite && shares > 0) {
            throw unusable
        }
        if let price = wire.currentSharePrice, !(price.isFinite && price > 0) {
            throw unusable
        }
        let sources = httpsSources(wire.sources)
        guard wire.sharesOutstanding != nil || wire.currentSharePrice != nil, !sources.isEmpty else { throw unusable }
        let currency = wire.currency?.trimmingCharacters(in: .whitespaces).uppercased()
        return ShareFactsSuggestion(
            ticker: ticker,
            sharesOutstanding: wire.sharesOutstanding,
            currentSharePrice: wire.currentSharePrice,
            currency: currency.flatMap { $0.count == 3 ? $0 : nil },
            asOf: wire.asOf,
            sources: sources
        )
    }

    static func parseScenario(_ content: String, ticker: String, horizonYears: Int) throws -> TerminalScenarioSuggestion {
        struct Wire: Decodable {
            let terminalShareCount: Double
            let terminalMarketCap: Double
            let rationale: String
            let sources: [String]?
        }
        let wire = try decodeObject(Wire.self, from: content)
        let rationale = wire.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = httpsSources(wire.sources)
        guard wire.terminalShareCount.isFinite, wire.terminalShareCount > 0,
              wire.terminalMarketCap.isFinite, wire.terminalMarketCap > 0,
              !rationale.isEmpty, rationale.count <= 600, !sources.isEmpty
        else { throw unusable }
        return TerminalScenarioSuggestion(
            ticker: ticker,
            terminalShareCount: wire.terminalShareCount,
            terminalMarketCap: wire.terminalMarketCap,
            horizonYears: horizonYears,
            rationale: rationale,
            sources: sources
        )
    }

    /// Models wrap JSON in fences or prose even under `json_object`: take the
    /// outermost object. Plain `JSONDecoder` so keys are read as written.
    private static func decodeObject<T: Decodable>(_: T.Type, from content: String) throws -> T {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            throw unusable
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(content[start ... end].utf8))
        } catch {
            throw unusable
        }
    }

    private static func httpsSources(_ raw: [String]?) -> [String] {
        (raw ?? []).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "https", url.host?.isEmpty == false else { return nil }
            return trimmed
        }
    }
}
