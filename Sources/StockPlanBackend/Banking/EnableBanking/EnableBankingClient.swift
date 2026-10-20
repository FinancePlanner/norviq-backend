import Foundation
import JWT
import JWTKit
import Vapor

struct EnableBankingConfiguration: Sendable {
    /// Application id from the Enable Banking Control Panel; sent as the JWT `kid`.
    let applicationID: String
    /// RSA private key (PEM) whose certificate was uploaded for the application.
    let privateKeyPEM: String
    let baseURL: String
    /// Overrides the callback URL derived from the request host. Enable Banking
    /// only redirects to URLs allow-listed on the application, so local dev
    /// (and any host the API is reached by internally) needs a fixed one.
    var redirectURL: String?

    static func fromEnvironment() -> EnableBankingConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }
        guard let applicationID = value("ENABLEBANKING_APP_ID"),
              let privateKeyPEM = value("ENABLEBANKING_PRIVATE_KEY_PEM")?.replacingOccurrences(of: "\\n", with: "\n")
        else {
            return nil
        }
        let base = value("ENABLEBANKING_API_BASE") ?? "https://api.enablebanking.com"
        return EnableBankingConfiguration(
            applicationID: applicationID,
            privateKeyPEM: privateKeyPEM,
            baseURL: base,
            redirectURL: value("ENABLEBANKING_REDIRECT_URL")
        )
    }
}

// MARK: - Wire models

struct EBASPSP: Content {
    let name: String
    let country: String
    let logo: String?
    let bic: String?
    let beta: Bool?
    /// Longest consent the bank grants, in seconds.
    let maximumConsentValidity: Int?

    enum CodingKeys: String, CodingKey {
        case name, country, logo, bic, beta
        case maximumConsentValidity = "maximum_consent_validity"
    }
}

struct EBASPSPsResponse: Content {
    let aspsps: [EBASPSP]
}

struct EBAuthResponse: Content {
    let url: String
    let authorizationId: String?

    enum CodingKeys: String, CodingKey {
        case url
        case authorizationId = "authorization_id"
    }
}

struct EBAccountIdentification: Content {
    let iban: String?
}

struct EBSessionAccount: Content {
    /// Session-scoped account id; dies with the session.
    let uid: String
    /// Stable across sessions for the same account — used to re-match on re-consent.
    let identificationHash: String?
    let name: String?
    let product: String?
    let currency: String?
    let cashAccountType: String?
    let accountId: EBAccountIdentification?

    enum CodingKeys: String, CodingKey {
        case uid, name, product, currency
        case identificationHash = "identification_hash"
        case cashAccountType = "cash_account_type"
        case accountId = "account_id"
    }
}

struct EBSessionAccess: Content {
    let validUntil: String?

    enum CodingKeys: String, CodingKey {
        case validUntil = "valid_until"
    }
}

struct EBSessionASPSP: Content {
    let name: String
    let country: String
}

struct EBSessionResponse: Content {
    let sessionId: String
    let accounts: [EBSessionAccount]
    let aspsp: EBSessionASPSP?
    let access: EBSessionAccess?

    enum CodingKeys: String, CodingKey {
        case accounts, aspsp, access
        case sessionId = "session_id"
    }
}

struct EBAmount: Content {
    let amount: String
    let currency: String?
}

struct EBParty: Content {
    let name: String?
}

struct EBTransaction: Content {
    /// Unique and immutable per account; the dedupe key when present.
    let entryReference: String?
    let transactionAmount: EBAmount
    /// "CRDT" (money in) or "DBIT" (money out).
    let creditDebitIndicator: String
    /// BOOK, PDNG, CNCL, HOLD, OTHR, RJCT or SCHD.
    let status: String
    let bookingDate: String?
    let valueDate: String?
    let transactionDate: String?
    let creditor: EBParty?
    let debtor: EBParty?
    let remittanceInformation: [String]?
    let merchantCategoryCode: String?

    enum CodingKeys: String, CodingKey {
        case status, creditor, debtor
        case entryReference = "entry_reference"
        case transactionAmount = "transaction_amount"
        case creditDebitIndicator = "credit_debit_indicator"
        case bookingDate = "booking_date"
        case valueDate = "value_date"
        case transactionDate = "transaction_date"
        case remittanceInformation = "remittance_information"
        case merchantCategoryCode = "merchant_category_code"
    }
}

struct EBTransactionsResponse: Content {
    let transactions: [EBTransaction]
    let continuationKey: String?

    enum CodingKeys: String, CodingKey {
        case transactions
        case continuationKey = "continuation_key"
    }
}

/// A non-2xx answer from Enable Banking, carrying its machine-readable `error`
/// code (e.g. `EXPIRED_SESSION`, `ASPSP_RATE_LIMIT_EXCEEDED`).
struct EnableBankingAPIError: AbortError {
    let statusCode: UInt
    let code: String?

    var status: HTTPResponseStatus {
        .badGateway
    }

    var reason: String {
        "Enable Banking request failed."
    }

    /// The bank consent is gone; only a new authorisation brings the connection back.
    var requiresReauth: Bool {
        guard let code else { return false }
        return Self.reauthCodes.contains(code)
    }

    static let reauthCodes: Set<String> = ["EXPIRED_SESSION", "CLOSED_SESSION", "REVOKED_SESSION", "SESSION_DOES_NOT_EXIST"]
}

/// Enable Banking account-information client. Read-only by design: it never
/// calls the payment endpoints. Every request carries a short-lived RS256 JWT
/// signed with the application's private key.
struct EnableBankingClient: Sendable {
    let config: EnableBankingConfiguration

    func aspsps(country: String, on req: Request) async throws -> [EBASPSP] {
        let uri = URI(string: config.baseURL + "/aspsps?country=\(country.uppercased())&psu_type=personal&service=AIS")
        let response = try await send(.GET, uri, path: "/aspsps", on: req)
        return try Self.decode(EBASPSPsResponse.self, from: response).aspsps
    }

    private struct AuthRequest: Content {
        struct Access: Content {
            let valid_until: String
        }

        struct ASPSP: Content {
            let name: String
            let country: String
        }

        let access: Access
        let aspsp: ASPSP
        let state: String
        let redirect_url: String
        let psu_type: String
    }

    func startAuthorization(
        aspspName: String,
        country: String,
        validUntil: Date,
        state: String,
        redirectURL: String,
        on req: Request
    ) async throws -> EBAuthResponse {
        let body = AuthRequest(
            access: .init(valid_until: Self.timestamp(validUntil)),
            aspsp: .init(name: aspspName, country: country.uppercased()),
            state: state,
            redirect_url: redirectURL,
            psu_type: "personal"
        )
        let response = try await send(.POST, URI(string: config.baseURL + "/auth"), path: "/auth", on: req) {
            try $0.content.encode(body)
        }
        return try Self.decode(EBAuthResponse.self, from: response)
    }

    private struct SessionRequest: Content {
        let code: String
    }

    func createSession(code: String, on req: Request) async throws -> EBSessionResponse {
        let response = try await send(.POST, URI(string: config.baseURL + "/sessions"), path: "/sessions", on: req) {
            try $0.content.encode(SessionRequest(code: code))
        }
        return try Self.decode(EBSessionResponse.self, from: response)
    }

    func deleteSession(id: String, on req: Request) async throws {
        do {
            _ = try await send(.DELETE, URI(string: config.baseURL + "/sessions/\(id)"), path: "/sessions/{id}", on: req)
        } catch let error as EnableBankingAPIError where error.statusCode == 404 || error.requiresReauth {
            // Already closed or expired is the outcome we wanted.
        }
    }

    /// Fetches every page for the account: Enable Banking may return an empty
    /// page with a continuation key, so only a null key ends the loop.
    func transactions(accountUID: String, dateFrom: String?, on req: Request) async throws -> [EBTransaction] {
        var all: [EBTransaction] = []
        var continuationKey: String?
        repeat {
            var components = URLComponents(string: config.baseURL + "/accounts/\(accountUID)/transactions")
            var items: [URLQueryItem] = []
            if let dateFrom {
                items.append(.init(name: "date_from", value: dateFrom))
            } else {
                // No history yet: ask for as much as the bank will give.
                items.append(.init(name: "strategy", value: "longest"))
            }
            if let continuationKey {
                items.append(.init(name: "continuation_key", value: continuationKey))
            }
            components?.queryItems = items
            guard let url = components?.string else {
                throw Abort(.internalServerError, reason: "Failed to build Enable Banking URL.")
            }
            let response = try await send(.GET, URI(string: url), path: "/accounts/{uid}/transactions", on: req)
            let page = try Self.decode(EBTransactionsResponse.self, from: response)
            all.append(contentsOf: page.transactions)
            continuationKey = page.continuationKey.flatMap { $0.isEmpty ? nil : $0 }
        } while continuationKey != nil
        return all
    }

    // MARK: - Transport

    private struct ErrorBody: Decodable {
        let error: String?
    }

    private func send(
        _ method: HTTPMethod,
        _ uri: URI,
        path: String,
        on req: Request,
        beforeSend: (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        let token = try await makeToken()
        let response = try await req.client.send(method, to: uri) { clientReq in
            clientReq.headers.bearerAuthorization = .init(token: token)
            clientReq.headers.contentType = .json
            try beforeSend(&clientReq)
        }
        guard (200 ..< 300).contains(response.status.code) else {
            let code = try? Self.decode(ErrorBody.self, from: response).error
            let bodyBytes = response.body?.readableBytes ?? 0
            // Code and length only: error bodies can echo account details.
            req.logger.warning("EnableBanking \(path) failed status=\(response.status.code) error=\(code ?? "-") body_bytes=\(bodyBytes)")
            throw EnableBankingAPIError(statusCode: response.status.code, code: code)
        }
        return response
    }

    /// Deliberately not `response.content.decode`: the global
    /// `JSONDecoder.backendAPI` camel-cases snake_case keys before `CodingKeys`
    /// lookup, so the explicit wire keys above would silently miss (see
    /// `OpenAIClient.decodeChatResponse`).
    private static func decode<T: Decodable>(_ type: T.Type, from response: ClientResponse) throws -> T {
        guard let body = response.body else {
            throw Abort(.badGateway, reason: "Enable Banking returned an empty body.")
        }
        return try JSONDecoder().decode(type, from: Data(buffer: body))
    }

    func makeToken(now: Date = Date()) async throws -> String {
        let keys = JWTKeyCollection()
        do {
            let key = try Insecure.RSA.PrivateKey(pem: config.privateKeyPEM)
            await keys.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: config.applicationID))
        } catch {
            throw Abort(.internalServerError, reason: "Invalid Enable Banking private key format.")
        }

        var header = JWTHeader()
        header.typ = "JWT"
        header.alg = "RS256"
        header.kid = config.applicationID

        let claims = EnableBankingClaims(
            iss: IssuerClaim(value: "enablebanking.com"),
            aud: AudienceClaim(value: ["api.enablebanking.com"]),
            iat: IssuedAtClaim(value: now),
            exp: ExpirationClaim(value: now.addingTimeInterval(3600))
        )
        return try await keys.sign(claims, header: header)
    }

    /// RFC 3339 with an explicit offset, as `/auth` requires.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct EnableBankingClaims: JWTPayload {
    let iss: IssuerClaim
    let aud: AudienceClaim
    let iat: IssuedAtClaim
    let exp: ExpirationClaim

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
