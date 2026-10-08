import Foundation
import StockPlanShared
import Vapor

protocol MarketBriefGenerating: Sendable {
    func generate(_ due: MarketBriefSchedule.Due, on req: Request) async throws -> GeneratedMarketBrief
}

struct GeneratedMarketBrief: Sendable, Equatable {
    /// One per `MarketBriefLanguage`, in `allCases` order.
    let responses: [MarketBriefResponse]
    let model: String
}

/// Builds one slot's brief in every language.
///
/// The numbers are fetched and formatted here; the model only writes text.
/// The first attempt uses a dedicated client on an OpenRouter `:online`
/// model (web search). If that call fails or its draft does not validate,
/// the app's ordinary chain writes the brief from the in-house facts alone
/// and it is marked `degraded`.
struct MarketBriefGenerator: MarketBriefGenerating {
    /// `:online` is OpenRouter's switch for web search; another provider would
    /// reject the slug, and the fallback then takes over.
    static let defaultModel = "anthropic/claude-haiku-4.5:online"
    static let fallbackModelLabel = "fallback-chain"

    let quotes: any IndexQuoteProvider
    let news: (any NewsProvider)?
    let earnings: any EarningsService
    let webClient: (any OpenAIChatClient)?
    let webModel: String
    /// Read lazily: `app.openAIChatClient` is set after this is built.
    let fallbackClient: @Sendable () -> any OpenAIChatClient
    let now: @Sendable () -> Date

    func generate(_ due: MarketBriefSchedule.Due, on req: Request) async throws -> GeneratedMarketBrief {
        let at = now()
        let quoteList = await quotes.quotes(
            symbols: MarketBriefCatalog.instruments(for: due.slot).map(\.symbol),
            now: at,
            on: req
        )
        let facts = await MarketBriefFacts.build(
            slot: due.slot,
            tradingDate: due.tradingDate,
            quotes: quoteList,
            news: headlines(on: req),
            earnings: calendar(date: due.tradingDate, on: req),
            now: at
        )

        if let webClient {
            do {
                return try await attempt(
                    webClient, webSearch: true, model: webModel, degraded: false,
                    due: due, facts: facts, quotes: quoteList, at: at, on: req
                )
            } catch {
                req.logger.warning(
                    "market_brief_web_attempt_failed",
                    metadata: ["slot": .string(due.slot.rawValue), "error": .string(String(describing: error))]
                )
            }
        }
        return try await attempt(
            fallbackClient(), webSearch: false, model: Self.fallbackModelLabel, degraded: true,
            due: due, facts: facts, quotes: quoteList, at: at, on: req
        )
    }

    private func attempt(
        _ client: any OpenAIChatClient,
        webSearch: Bool,
        model: String,
        degraded: Bool,
        due: MarketBriefSchedule.Due,
        facts: MarketBriefFacts,
        quotes: [IndexQuote],
        at: Date,
        on req: Request
    ) async throws -> GeneratedMarketBrief {
        let reply = try await client.chat(
            messages: MarketBriefPrompt.messages(facts: facts, webSearch: webSearch),
            tools: [],
            responseFormat: "json_object",
            on: req
        )
        let draft = try MarketBriefDraft.parse(reply.content ?? "")
        let generatedAt = ISO8601DateFormatter().string(from: at)
        let grounded = facts.groundedNumbers
        let responses = try MarketBriefLanguage.allCases.map { language in
            let output = try MarketBriefValidator.validate(
                draft.section(language), slot: due.slot, language: language, grounded: grounded
            )
            if output.dropped > 0 {
                req.logger.info(
                    "market_brief_items_dropped",
                    metadata: ["language": .string(language.rawValue), "dropped": .stringConvertible(output.dropped)]
                )
            }
            return MarketBriefResponse(
                enabled: true,
                tradingDate: due.tradingDate,
                slot: due.slot,
                language: language.rawValue,
                greeting: output.greeting,
                groups: MarketBriefFormatter.groups(slot: due.slot, quotes: quotes, language: language),
                items: output.items,
                generatedAt: generatedAt,
                degraded: degraded
            )
        }
        return GeneratedMarketBrief(responses: responses, model: model)
    }

    private func headlines(on req: Request) async -> [ProviderNewsItem] {
        guard let news else { return [] }
        do {
            return try await news.fetchGeneral(on: req)
        } catch {
            req.logger.warning("market_brief_news_failed", metadata: ["error": .string(String(describing: error))])
            return []
        }
    }

    private func calendar(date: String, on req: Request) async -> [EarningsItemResponse] {
        do {
            return try await earnings.getCalendar(query: EarningsQueryRequest(from: date, to: date), on: req)
        } catch {
            req.logger.warning("market_brief_earnings_failed", metadata: ["error": .string(String(describing: error))])
            return []
        }
    }
}

extension MarketBriefGenerator {
    /// Production wiring. The web client reuses the configured AI key and base
    /// URL with its own model and a longer timeout, since web search adds
    /// latency. No key means no web client, and every run is degraded.
    static func live(app: Application, news: (any NewsProvider)?) -> MarketBriefGenerator {
        let config = AIProviderConfiguration.load()
        let configured = Environment.get("MARKET_BRIEF_MODEL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configured.isEmpty ? defaultModel : configured
        let webClient: (any OpenAIChatClient)? = config.apiKey.isEmpty || config.baseURL.isEmpty
            ? nil
            : DefaultOpenAIChatClient(
                apiKey: config.apiKey,
                model: model,
                baseURL: config.baseURL,
                maxTokens: 6000,
                timeout: .seconds(90)
            )
        return MarketBriefGenerator(
            quotes: YahooChartQuoteProvider(),
            news: news,
            earnings: app.earningsService,
            webClient: webClient,
            webModel: model,
            fallbackClient: { app.openAIChatClient },
            now: { Date() }
        )
    }
}
