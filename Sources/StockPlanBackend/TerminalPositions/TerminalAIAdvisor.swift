import Foundation
import StockPlanShared
import Vapor

/// AI suggestions for terminal position sizing. One web-search chat call per
/// suggestion, strict JSON, validated before it reaches the user. It never
/// writes: the user accepts a suggestion in the UI, which then PATCHes.
///
/// No sampling parameters are sent (some Anthropic models reject them), and there is no
/// fallback without web search — a guessed share count is worse than none.
struct TerminalAIAdvisor: Sendable {
    /// OpenRouter's `:online` slug turns on web search.
    static let defaultModel = "anthropic/claude-haiku-4.5:online"
    static let defaultHorizonYears = 10

    let client: any OpenAIChatClient

    /// Why there is no client, or nil when one can be built. The default model is
    /// an OpenRouter slug, so any other provider needs `TERMINAL_AI_MODEL`.
    static func unavailableReason(provider: AIProviderKind, apiKey: String, baseURL: String, configuredModel: String?) -> String? {
        guard !apiKey.isEmpty, !baseURL.isEmpty else { return "no AI API key or base URL configured" }
        let hasModel = !(configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if provider != .openRouter, !hasModel {
            return "AI_PROVIDER is \(provider.rawValue) and TERMINAL_AI_MODEL is unset; the default model is an OpenRouter slug"
        }
        return nil
    }

    static func liveClient() -> (any OpenAIChatClient)? {
        let config = AIProviderConfiguration.load()
        return liveClient(provider: config.provider, apiKey: config.apiKey, baseURL: config.baseURL, configuredModel: Environment.get("TERMINAL_AI_MODEL"))
    }

    static func liveClient(provider: AIProviderKind, apiKey: String, baseURL: String, configuredModel: String?) -> (any OpenAIChatClient)? {
        guard unavailableReason(provider: provider, apiKey: apiKey, baseURL: baseURL, configuredModel: configuredModel) == nil else {
            return nil
        }
        let configured = configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DefaultOpenAIChatClient(
            apiKey: apiKey,
            model: configured.isEmpty ? defaultModel : configured,
            baseURL: baseURL,
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
    latest price, quoted in the currency named in the request; if you can only find it in another currency, \
    report the price you found and set "currency" to that currency's ISO code. Every number must come from a \
    source you list; if you cannot find one, use null. Never estimate.
    """

    static let scenarioPrompt = """
    You help an investor sketch ONE terminal scenario for a stock with web search. Reply with only a JSON object:
    {"terminalShareCount": number, "terminalMarketCap": number, "rationale": string, "sources": ["https://..."]}
    terminalShareCount is the share count you expect at the horizon given the dilution or buyback trend in \
    filings. terminalMarketCap is a market cap at the horizon grounded in published analyst ranges or the \
    company's historical growth, as a plain number converted to the currency named in the request (not the \
    company's reporting currency). rationale is 1-3 sentences naming what the numbers rest on and stating the \
    currency the market cap is in. This is an assumption to be edited by the user, not a forecast \
    or advice.
    """

    func shareFacts(ticker: String, currency: String, on req: Request) async throws -> ShareFactsSuggestion {
        let content = try await ask(system: Self.shareFactsPrompt, user: "Ticker: \(ticker). Currency: \(currency).", on: req)
        return try Self.parseShareFacts(content, ticker: ticker)
    }

    func scenario(ticker: String, horizonYears: Int?, currency: String, on req: Request) async throws -> TerminalScenarioSuggestion {
        let horizon = min(max(horizonYears ?? Self.defaultHorizonYears, 1), 30)
        let content = try await ask(
            system: Self.scenarioPrompt,
            user: "Ticker: \(ticker). Horizon: \(horizon) years. Currency: \(currency) (give terminalMarketCap in \(currency)).",
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
