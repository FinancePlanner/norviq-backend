import Foundation
import StockPlanShared
import Vapor

/// One image's worth of extracted portfolio rows.
struct ScreenshotExtraction: Sendable {
    let kind: ScreenshotImportKind
    let rows: [ScreenshotExtractedRow]
    /// A human-readable reason the image yielded nothing, when it yielded nothing.
    let rejection: String?

    static func rejected(_ reason: String, kind: ScreenshotImportKind = .unknown) -> ScreenshotExtraction {
        ScreenshotExtraction(kind: kind, rows: [], rejection: reason)
    }
}

struct ScreenshotExtractedRow: Sendable {
    let symbol: String
    let shares: Double?
    let buyPrice: Double?
    let buyDate: String?
    let confidence: Double?
}

/// Reads broker screenshots into portfolio rows.
protocol ScreenshotPortfolioExtractor: Sendable {
    var isEnabled: Bool { get }

    func extract(imageData: Data, contentType: String, on req: Request) async throws -> ScreenshotExtraction
}

struct DisabledScreenshotPortfolioExtractor: ScreenshotPortfolioExtractor {
    var isEnabled: Bool {
        false
    }

    func extract(imageData _: Data, contentType _: String, on _: Request) async throws -> ScreenshotExtraction {
        .rejected("Screenshot import is not available.")
    }
}

/// Broker-screenshot extraction via an OpenAI-compatible vision chat model.
///
/// Classifies before extracting. The distinction matters for money: a holdings
/// list states what you own *now*, so its price column is market value, not cost
/// basis — writing it into `buyPrice` would invent a fictional purchase and
/// silently zero out the position's gain. Trade confirmations do carry a real
/// per-lot price and date. When the model cannot tell which it is looking at,
/// the image is rejected rather than guessed.
struct OpenAIVisionScreenshotExtractor: ScreenshotPortfolioExtractor {
    let apiKey: String
    let baseURL: String
    let model: String

    /// A dense holdings table can run to dozens of rows.
    private let maxTokens = 3000

    var isEnabled: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    func extract(imageData: Data, contentType: String, on req: Request) async throws -> ScreenshotExtraction {
        guard isEnabled else { return .rejected("Screenshot import is not available.") }

        let body = VisionRequest(
            model: model,
            messages: [
                VisionMessage(role: "system", content: [.text(Self.systemPrompt)]),
                VisionMessage(role: "user", content: [
                    .text("Classify this screenshot and extract its rows. Return the JSON object."),
                    .image(data: imageData, contentType: contentType),
                ]),
            ],
            temperature: 0,
            maxTokens: maxTokens,
            responseFormat: .json
        )

        let jsonText = try await VisionChatCaller.completeJSON(
            body,
            apiKey: apiKey,
            baseURL: baseURL,
            feature: "portfolio_screenshot",
            on: req
        )

        guard
            let jsonText,
            let jsonData = jsonText.data(using: .utf8),
            let extracted = try? JSONDecoder().decode(ExtractedScreenshot.self, from: jsonData)
        else {
            req.logger.warning("portfolio_screenshot_undecodable model=\(model)")
            return .rejected("Could not read this image. Try a sharper, uncropped screenshot.")
        }

        return extracted.toExtraction()
    }

    private static let systemPrompt = """
    You read a screenshot from a stock broker or investing app and turn it into \
    structured rows. Respond with a single JSON object and nothing else:
    {"kind": "holdings" | "trades" | "unknown",
     "rows": [{"symbol": string, "shares": number|null, "buyPrice": number|null, \
    "buyDate": string|null (YYYY-MM-DD), "confidence": number (0..1)}]}

    First classify:
    - "holdings": a positions or portfolio list — what the user owns right now.
    - "trades": trade confirmations, order history or executions — individual \
    buys and sells with a price and a date.
    - "unknown": anything else (a chart, a news screen, a watchlist with no \
    quantities, a bank statement), or an image too blurred or cropped to read. \
    Return "unknown" with an empty rows array. Do not force a classification.

    Then extract, one row per visible position or trade:
    - "symbol" is the exchange ticker, uppercase, without the exchange prefix or \
    suffix (write "AAPL", not "NASDAQ:AAPL" or "AAPL.US"). If only a company name \
    is shown and you are not certain of its ticker, skip the row.
    - "shares" is the quantity held or traded. Fractional values are normal.
    - For kind "holdings": set "buyPrice" ONLY if the screen explicitly labels a \
    cost basis, average cost or average price. A last price, market price, current \
    value or day-change figure is NOT a buy price — set null. This is the single \
    most damaging mistake you can make here.
    - For kind "trades": "buyPrice" is the execution price per share and "buyDate" \
    the execution date. Include only BUY rows; skip sells, dividends and fees.
    - "confidence" is your own 0..1 certainty for that row's numbers.
    - Never guess a number. Null is always better than a plausible invention — \
    these values become someone's financial records.
    """
}

// MARK: - Extracted JSON → rows

/// Internal rather than private so the mapping rules — especially the
/// holdings-screen `buyPrice` suppression — are directly testable without a
/// live model call.
struct ExtractedScreenshot: Decodable {
    var kind: String?
    var rows: [ExtractedRow]?

    struct ExtractedRow: Decodable {
        var symbol: String?
        var shares: Double?
        var buyPrice: Double?
        var buyDate: String?
        var confidence: Double?
    }

    func toExtraction() -> ScreenshotExtraction {
        let kind = ScreenshotImportKind(rawValue: kind?.lowercased() ?? "") ?? .unknown
        guard kind != .unknown else {
            return .rejected(
                "This doesn't look like a portfolio or trade screen. Upload a holdings list or a trade confirmation.",
                kind: .unknown
            )
        }

        let rows = (rows ?? []).compactMap { raw -> ScreenshotExtractedRow? in
            guard let symbol = raw.symbol?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .nilIfEmpty
            else {
                return nil
            }
            return ScreenshotExtractedRow(
                symbol: symbol,
                shares: raw.shares,
                // A holdings screen's price column is market value, not cost basis.
                // The prompt already forbids it, but enforce it here too: a model
                // that ignores the instruction must not be able to write a fake
                // cost basis into someone's portfolio.
                buyPrice: kind == .trades ? raw.buyPrice : nil,
                buyDate: kind == .trades ? raw.buyDate : nil,
                confidence: raw.confidence
            )
        }

        guard !rows.isEmpty else {
            return .rejected("No positions could be read from this image.", kind: kind)
        }
        return ScreenshotExtraction(kind: kind, rows: rows, rejection: nil)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Bootstrap

enum ScreenshotPortfolioExtractorBootstrap {
    /// Shares `RECEIPT_OCR_PROVIDER` as the on/off switch — both features are the
    /// same capability (a vision call on the same credentials), and a deployment
    /// that wants one and not the other has never come up. The model is pinned
    /// separately via `PORTFOLIO_SCREENSHOT_MODEL` because broker tables are
    /// denser than receipts and may need a stronger model than `RECEIPT_OCR_MODEL`.
    static func fromEnvironment(app: Application) -> any ScreenshotPortfolioExtractor {
        let configured = Environment.get("RECEIPT_OCR_PROVIDER")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .openAIVision = ReceiptOCRProviderKind.select(configured: configured) else {
            return DisabledScreenshotPortfolioExtractor()
        }

        let config = AIProviderConfiguration.load()
        let pinned = Environment.get("PORTFOLIO_SCREENSHOT_MODEL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let receiptModel = Environment.get("RECEIPT_OCR_MODEL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = [pinned, receiptModel, config.chatModel].first { !$0.isEmpty } ?? ""

        let extractor = OpenAIVisionScreenshotExtractor(
            apiKey: config.apiKey,
            baseURL: config.baseURL,
            model: model
        )
        guard extractor.isEnabled else {
            app.logger.warning("Portfolio screenshot import enabled but AI credentials/model are missing; disabled.")
            return DisabledScreenshotPortfolioExtractor()
        }
        app.logger.notice("portfolio_screenshot configured model=\(model)")
        return extractor
    }
}

extension Application {
    struct ScreenshotPortfolioExtractorKey: StorageKey {
        typealias Value = any ScreenshotPortfolioExtractor
    }

    var screenshotPortfolioExtractor: any ScreenshotPortfolioExtractor {
        get { storage[ScreenshotPortfolioExtractorKey.self] ?? DisabledScreenshotPortfolioExtractor() }
        set { storage[ScreenshotPortfolioExtractorKey.self] = newValue }
    }
}

extension Request {
    var screenshotPortfolioExtractor: any ScreenshotPortfolioExtractor {
        application.screenshotPortfolioExtractor
    }
}
