import Vapor

/// Feature tokens a client announces in `X-StockPlan-Client-Capabilities`
/// (comma-separated, case-insensitive), e.g. `mfa-auth-v1`, `ai-consent-v1`.
/// Lets the server tell a client that understands a new response from one
/// that would break on it.
enum ClientCapabilities {
    static let header = "X-StockPlan-Client-Capabilities"

    static func has(_ token: String, in req: Request) -> Bool {
        let raw = req.headers.first(name: header) ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(token.lowercased())
    }
}
