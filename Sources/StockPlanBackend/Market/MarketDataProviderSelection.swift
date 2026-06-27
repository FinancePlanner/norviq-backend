import Foundation

enum MarketDataProviderKind: Equatable {
    case finnhub
    case ibkr
    case disabled

    static func select(
        configuredMarketProvider rawConfiguredMarketProvider: String?,
        hasFinnhubAPIKey: Bool,
        hasIBKRBaseURL: Bool
    ) -> MarketDataProviderKind {
        switch rawConfiguredMarketProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "finnhub":
            return hasFinnhubAPIKey ? .finnhub : .disabled
        case "ibkr":
            return hasIBKRBaseURL ? .ibkr : .disabled
        default:
            if hasFinnhubAPIKey {
                return .finnhub
            }
            if hasIBKRBaseURL {
                return .ibkr
            }
            return .disabled
        }
    }
}
