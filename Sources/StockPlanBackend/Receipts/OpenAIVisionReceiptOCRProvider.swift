import Foundation
import StockPlanShared
import Vapor

/// Receipt OCR via an OpenAI-compatible vision chat model. Sends the receipt
/// image as a base64 data URL and asks for a strict JSON object, which is
/// decoded into a `ReceiptDraft`. The multimodal request shape lives in
/// `AI/VisionChatWire.swift` because the assistant's `OpenAIMessage.content` is
/// a plain string and cannot carry images. Credentials/base URL are shared with
/// the AI assistant (`AIProviderConfiguration`); the model is chosen separately
/// so a vision-capable model can be pinned without changing the chat model.
struct OpenAIVisionReceiptOCRProvider: ReceiptOCRProvider {
    let apiKey: String
    let baseURL: String
    let model: String

    /// Enough budget for a long supermarket receipt's line items. The previous
    /// 500 covered only the header fields; a 25-line receipt truncates at that
    /// size and the whole JSON object then fails to decode.
    private let maxTokens = 2000

    var isEnabled: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    func extract(imageData: Data, contentType: String, on req: Request) async throws -> ReceiptDraft? {
        guard isEnabled else { return nil }

        let body = VisionRequest(
            model: model,
            messages: [
                VisionMessage(role: "system", content: [.text(Self.systemPrompt)]),
                VisionMessage(role: "user", content: [
                    .text("Extract the fields from this receipt image and return the JSON object."),
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
            feature: "receipt_ocr",
            on: req
        )

        guard
            let jsonText,
            let jsonData = jsonText.data(using: .utf8),
            let extracted = try? JSONDecoder().decode(ExtractedReceipt.self, from: jsonData),
            extracted.hasContent
        else {
            return nil
        }
        return extracted.toDraft()
    }

    private static let systemPrompt = """
    You extract structured data from a photographed shop receipt. Respond with a \
    single JSON object and nothing else, using exactly these keys (use null when a \
    value is not clearly legible — never guess):
    {"merchant": string|null, "total": number|null, "currency": string|null (ISO 4217, e.g. "EUR"), \
    "date": string|null (YYYY-MM-DD), "taxId": string|null (merchant tax/VAT id), \
    "taxTotal": number|null (total VAT/tax amount), \
    "lineItems": [{"description": string, "amount": number, "quantity": number|null}]}
    Amounts are numbers without currency symbols. If the image is not a receipt, \
    return all null values and an empty lineItems array.

    lineItems rules:
    - One entry per purchased article, in the order printed.
    - "amount" is the line total as printed, with quantity already applied. Do not \
    multiply it yourself.
    - "quantity" only when the receipt states units; otherwise null.
    - Omit non-article lines: subtotals, totals, VAT summaries, discounts applied \
    to the whole basket, loyalty points, change given, payment method lines.
    - If the articles are not legible enough to read individually, return an empty \
    array. A partial list is worse than none, because the totals will not reconcile.
    """
}

// MARK: - Extracted JSON → ReceiptDraft

/// Internal rather than private so the line-item normalisation rules are
/// testable without a live model call.
struct ExtractedReceipt: Decodable {
    var merchant: String?
    var total: Double?
    var currency: String?
    var date: String?
    var taxId: String?
    var taxTotal: Double?
    var lineItems: [ExtractedLineItem]?

    struct ExtractedLineItem: Decodable {
        var description: String?
        var amount: Double?
        var quantity: Double?
    }

    var hasContent: Bool {
        merchant != nil || total != nil || taxId != nil || taxTotal != nil || !(lineItems ?? []).isEmpty
    }

    func toDraft() -> ReceiptDraft {
        ReceiptDraft(
            merchant: merchant?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            total: total,
            currency: currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty,
            date: date?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            taxId: taxId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            taxTotal: taxTotal,
            vatLines: [],
            lineItems: normalizedLineItems,
            confidence: 0.6,
            source: .ocr,
            rawPayload: nil
        )
    }

    /// Drops entries the model returned without the two fields that make a line
    /// usable. A line with no amount cannot become an expense, and one with no
    /// description cannot be reviewed, so neither is worth showing.
    var normalizedLineItems: [ReceiptLineItem] {
        (lineItems ?? []).compactMap { raw in
            guard
                let description = raw.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                let amount = raw.amount
            else {
                return nil
            }
            return ReceiptLineItem(description: description, amount: amount, quantity: raw.quantity)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
