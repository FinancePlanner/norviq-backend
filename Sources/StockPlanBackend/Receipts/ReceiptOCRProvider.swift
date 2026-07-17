import StockPlanShared
import Vapor

/// Extracts a structured expense draft from a receipt photo. Implementations
/// wrap a vision/OCR backend; selection is by environment so a hosted vision
/// model or a self-hosted OCR engine can be swapped without touching callers.
protocol ReceiptOCRProvider: Sendable {
    /// Whether OCR is configured. When false, the endpoint reports 503 so
    /// clients fall back to on-device OCR or manual entry.
    var isEnabled: Bool { get }

    /// Extract a draft from raw image bytes. Returns nil when nothing usable was
    /// recognized. Implementations must not persist the image.
    func extract(imageData: Data, contentType: String, on req: Request) async throws -> ReceiptDraft?
}

/// Null provider used when no OCR backend is configured. Structured fiscal-QR
/// parsing still works without it; only photo OCR is unavailable.
struct DisabledReceiptOCRProvider: ReceiptOCRProvider {
    var isEnabled: Bool {
        false
    }

    func extract(imageData _: Data, contentType _: String, on _: Request) async throws -> ReceiptDraft? {
        nil
    }
}

enum ReceiptOCRProviderKind: String {
    case disabled
    case openAIVision

    static func select(configured: String?) -> ReceiptOCRProviderKind {
        switch configured?.lowercased() {
        case "openai", "openai-vision", "vision":
            .openAIVision
        case "disabled", "", nil:
            .disabled
        default:
            .disabled
        }
    }
}

enum ReceiptOCRProviderBootstrap {
    /// Selects the OCR provider from `RECEIPT_OCR_PROVIDER`. Defaults to disabled.
    /// `openai` wires the vision provider, reusing the assistant's AI credentials
    /// (`AIProviderConfiguration`) with a model overridable via `RECEIPT_OCR_MODEL`.
    static func fromEnvironment(app: Application) -> any ReceiptOCRProvider {
        let configured = Environment.get("RECEIPT_OCR_PROVIDER")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch ReceiptOCRProviderKind.select(configured: configured) {
        case .openAIVision:
            let config = AIProviderConfiguration.load()
            let rawModel = Environment.get("RECEIPT_OCR_MODEL")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = rawModel.isEmpty ? config.chatModel : rawModel
            let provider = OpenAIVisionReceiptOCRProvider(
                apiKey: config.apiKey,
                baseURL: config.baseURL,
                model: model
            )
            guard provider.isEnabled else {
                app.logger.warning("RECEIPT_OCR_PROVIDER=\(configured ?? "") set but AI credentials/model are missing; receipt OCR disabled.")
                return DisabledReceiptOCRProvider()
            }
            app.logger.notice("receipt_ocr configured provider=openai-vision model=\(model)")
            return provider
        case .disabled:
            if let configured, !configured.isEmpty, configured.lowercased() != "disabled" {
                app.logger.warning("RECEIPT_OCR_PROVIDER=\(configured) is not recognized; receipt OCR disabled.")
            }
            return DisabledReceiptOCRProvider()
        }
    }
}

extension Application {
    struct ReceiptOCRProviderKey: StorageKey {
        typealias Value = any ReceiptOCRProvider
    }

    var receiptOCRProvider: any ReceiptOCRProvider {
        get { storage[ReceiptOCRProviderKey.self] ?? DisabledReceiptOCRProvider() }
        set { storage[ReceiptOCRProviderKey.self] = newValue }
    }
}

extension Request {
    var receiptOCRProvider: any ReceiptOCRProvider {
        application.receiptOCRProvider
    }
}
