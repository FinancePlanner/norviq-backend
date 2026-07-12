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

    static func select(configured: String?) -> ReceiptOCRProviderKind {
        switch configured?.lowercased() {
        case "disabled", "", nil:
            .disabled
        default:
            .disabled
        }
    }
}

enum ReceiptOCRProviderBootstrap {
    /// Selects the OCR provider from `RECEIPT_OCR_PROVIDER`. Defaults to disabled;
    /// a live vision/OCR driver plugs in here.
    static func fromEnvironment(app: Application) -> any ReceiptOCRProvider {
        let configured = Environment.get("RECEIPT_OCR_PROVIDER")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch ReceiptOCRProviderKind.select(configured: configured) {
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
