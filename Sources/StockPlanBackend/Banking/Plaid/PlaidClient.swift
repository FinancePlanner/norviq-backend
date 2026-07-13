import Foundation
import Vapor

/// Configuration for the Plaid API, read from the environment.
struct PlaidConfiguration: Sendable {
    let clientID: String
    let secret: String
    let baseURL: String
    /// Webhook URL Plaid calls on new transactions. Optional in sandbox.
    let webhookURL: String?

    static func fromEnvironment() -> PlaidConfiguration? {
        guard let clientID = bankingTrimmedNonEmpty(Environment.get("PLAID_CLIENT_ID")),
              let secret = bankingTrimmedNonEmpty(Environment.get("PLAID_SECRET"))
        else {
            return nil
        }
        let env = bankingTrimmedNonEmpty(Environment.get("PLAID_ENV"))?.lowercased() ?? "sandbox"
        let host = switch env {
        case "production": "https://production.plaid.com"
        case "development": "https://development.plaid.com"
        default: "https://sandbox.plaid.com"
        }
        return PlaidConfiguration(
            clientID: clientID,
            secret: secret,
            baseURL: host,
            webhookURL: bankingTrimmedNonEmpty(Environment.get("PLAID_WEBHOOK_URL"))
        )
    }
}

// MARK: - Wire models

struct PlaidLinkTokenResponse: Content {
    let linkToken: String
    let expiration: String?

    enum CodingKeys: String, CodingKey {
        case linkToken = "link_token"
        case expiration
    }
}

struct PlaidExchangeResponse: Content {
    let accessToken: String
    let itemId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case itemId = "item_id"
    }
}

struct PlaidAccount: Content {
    let accountId: String
    let name: String
    let mask: String?
    let type: String?
    let balances: PlaidBalances?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case name, mask, type, balances
    }
}

struct PlaidBalances: Content {
    let current: Double?
    let isoCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case current
        case isoCurrencyCode = "iso_currency_code"
    }
}

struct PlaidAccountsResponse: Content {
    let accounts: [PlaidAccount]
}

struct PlaidTransaction: Content {
    let transactionId: String
    let accountId: String
    let amount: Double
    let isoCurrencyCode: String?
    let date: String
    let name: String?
    let merchantName: String?
    let pending: Bool
    let category: [String]?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case accountId = "account_id"
        case amount
        case isoCurrencyCode = "iso_currency_code"
        case date, name, pending, category
        case merchantName = "merchant_name"
    }
}

struct PlaidRemovedTransaction: Content {
    let transactionId: String

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
    }
}

struct PlaidSyncResponse: Content {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    let nextCursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case added, modified, removed
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

/// Thin Plaid REST client. All calls are read-only against the institution
/// (transactions + balances only); no auth/transfer/payment products.
struct PlaidClient: Sendable {
    let config: PlaidConfiguration

    func createLinkToken(userId: UUID, on req: Request) async throws -> PlaidLinkTokenResponse {
        var body: [String: any Encodable] = [
            "user": ["client_user_id": userId.uuidString],
            "client_name": "Norviq",
            "products": ["transactions"],
            "country_codes": ["US"],
            "language": "en",
        ]
        if let webhook = config.webhookURL {
            body["webhook"] = webhook
        }
        return try await post("/link/token/create", body: body, on: req)
    }

    func exchangePublicToken(_ publicToken: String, on req: Request) async throws -> PlaidExchangeResponse {
        try await post("/item/public_token/exchange", body: ["public_token": publicToken], on: req)
    }

    func accounts(accessToken: String, on req: Request) async throws -> PlaidAccountsResponse {
        try await post("/accounts/get", body: ["access_token": accessToken], on: req)
    }

    func transactionsSync(accessToken: String, cursor: String?, on req: Request) async throws -> PlaidSyncResponse {
        var body: [String: any Encodable] = ["access_token": accessToken]
        if let cursor {
            body["cursor"] = cursor
        }
        return try await post("/transactions/sync", body: body, on: req)
    }

    func removeItem(accessToken: String, on req: Request) async throws {
        let _: PlaidEmptyResponse = try await post("/item/remove", body: ["access_token": accessToken], on: req)
    }

    // MARK: - Transport

    private struct PlaidEmptyResponse: Content {}

    private func post<T: Content>(_ path: String, body: [String: any Encodable], on req: Request) async throws -> T {
        var payload = body
        payload["client_id"] = config.clientID
        payload["secret"] = config.secret

        let uri = URI(string: config.baseURL + path)
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            try clientReq.content.encode(AnyEncodableDict(payload), as: .json)
        }

        guard response.status == .ok else {
            let detail = response.body.map { String(buffer: $0) } ?? ""
            req.logger.warning("Plaid \(path) failed status=\(response.status.code) body=\(detail.prefix(300))")
            throw Abort(.badGateway, reason: "Plaid request failed.")
        }
        return try response.content.decode(T.self)
    }
}

/// Encodes a heterogenous `[String: Encodable]` body for Plaid requests.
private struct AnyEncodableDict: Encodable {
    let values: [String: any Encodable]

    init(_ values: [String: any Encodable]) {
        self.values = values
    }

    struct StringKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        var intValue: Int? {
            nil
        }

        init?(intValue _: Int) {
            nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: StringKey.self)
        for (key, value) in values {
            try container.encode(AnyEncodable(value), forKey: StringKey(stringValue: key)!)
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
