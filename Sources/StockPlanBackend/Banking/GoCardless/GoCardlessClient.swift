import Foundation
import Vapor

struct GoCardlessConfiguration: Sendable {
    let secretID: String
    let secretKey: String
    let baseURL: String

    static func fromEnvironment() -> GoCardlessConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }
        guard let secretID = value("GOCARDLESS_SECRET_ID"), let secretKey = value("GOCARDLESS_SECRET_KEY") else {
            return nil
        }
        let base = value("GOCARDLESS_API_BASE") ?? "https://bankaccountdata.gocardless.com/api/v2"
        return GoCardlessConfiguration(secretID: secretID, secretKey: secretKey, baseURL: base)
    }
}

// MARK: - Wire models

struct GCTokenResponse: Content {
    let access: String
}

struct GCInstitution: Content {
    let id: String
    let name: String
    let bic: String?
    let logo: String?
    let countries: [String]?
}

struct GCAgreementResponse: Content {
    let id: String
}

struct GCRequisitionResponse: Content {
    let id: String
    let link: String?
    let status: String?
    let accounts: [String]?
}

struct GCAccountDetails: Content {
    struct Account: Content {
        let name: String?
        let ownerName: String?
        let currency: String?
        let iban: String?
        let product: String?
    }

    let account: Account
}

struct GCTransactionAmount: Content {
    let amount: String
    let currency: String?
}

struct GCTransaction: Content {
    let transactionId: String?
    let internalTransactionId: String?
    let bookingDate: String?
    let valueDate: String?
    let transactionAmount: GCTransactionAmount
    let remittanceInformationUnstructured: String?
    let creditorName: String?
    let debtorName: String?
}

struct GCTransactionsResponse: Content {
    struct Bucket: Content {
        let booked: [GCTransaction]?
        let pending: [GCTransaction]?
    }

    let transactions: Bucket
}

/// GoCardless Bank Account Data (AIS-only) client. Every call is read-only —
/// the API surface has no payment or transfer capability.
struct GoCardlessClient: Sendable {
    let config: GoCardlessConfiguration

    private struct TokenRequest: Content {
        let secret_id: String
        let secret_key: String
    }

    func newAccessToken(on req: Request) async throws -> String {
        let response = try await req.client.post(URI(string: config.baseURL + "/token/new/")) { clientReq in
            clientReq.headers.contentType = .json
            try clientReq.content.encode(TokenRequest(secret_id: config.secretID, secret_key: config.secretKey))
        }
        try Self.ensureOK(response, req: req, path: "/token/new/")
        return try response.content.decode(GCTokenResponse.self).access
    }

    func institutions(country: String, accessToken: String, on req: Request) async throws -> [GCInstitution] {
        let uri = URI(string: config.baseURL + "/institutions/?country=\(country.uppercased())")
        let response = try await req.client.get(uri) { $0.headers.bearerAuthorization = .init(token: accessToken) }
        try Self.ensureOK(response, req: req, path: "/institutions/")
        return try response.content.decode([GCInstitution].self)
    }

    private struct AgreementRequest: Content {
        let institution_id: String
        let max_historical_days: Int
        let access_valid_for_days: Int
        let access_scope: [String]
    }

    func createAgreement(institutionId: String, accessToken: String, on req: Request) async throws -> String {
        let body = AgreementRequest(
            institution_id: institutionId,
            max_historical_days: 90,
            access_valid_for_days: 90,
            access_scope: ["balances", "details", "transactions"]
        )
        let response = try await req.client.post(URI(string: config.baseURL + "/agreements/enduser/")) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = .init(token: accessToken)
            try clientReq.content.encode(body)
        }
        try Self.ensureOK(response, req: req, path: "/agreements/enduser/")
        return try response.content.decode(GCAgreementResponse.self).id
    }

    private struct RequisitionRequest: Content {
        let institution_id: String
        let redirect: String
        let agreement: String
        let reference: String
    }

    func createRequisition(institutionId: String, redirect: String, agreementId: String, reference: String, accessToken: String, on req: Request) async throws -> GCRequisitionResponse {
        let body = RequisitionRequest(institution_id: institutionId, redirect: redirect, agreement: agreementId, reference: reference)
        let response = try await req.client.post(URI(string: config.baseURL + "/requisitions/")) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = .init(token: accessToken)
            try clientReq.content.encode(body)
        }
        try Self.ensureOK(response, req: req, path: "/requisitions/")
        return try response.content.decode(GCRequisitionResponse.self)
    }

    func requisition(id: String, accessToken: String, on req: Request) async throws -> GCRequisitionResponse {
        let response = try await req.client.get(URI(string: config.baseURL + "/requisitions/\(id)/")) {
            $0.headers.bearerAuthorization = .init(token: accessToken)
        }
        try Self.ensureOK(response, req: req, path: "/requisitions/{id}/")
        return try response.content.decode(GCRequisitionResponse.self)
    }

    func deleteRequisition(id: String, accessToken: String, on req: Request) async throws {
        _ = try await req.client.delete(URI(string: config.baseURL + "/requisitions/\(id)/")) {
            $0.headers.bearerAuthorization = .init(token: accessToken)
        }
    }

    func accountDetails(accountId: String, accessToken: String, on req: Request) async throws -> GCAccountDetails {
        let response = try await req.client.get(URI(string: config.baseURL + "/accounts/\(accountId)/details/")) {
            $0.headers.bearerAuthorization = .init(token: accessToken)
        }
        try Self.ensureOK(response, req: req, path: "/accounts/{id}/details/")
        return try response.content.decode(GCAccountDetails.self)
    }

    func transactions(accountId: String, accessToken: String, on req: Request) async throws -> GCTransactionsResponse {
        let response = try await req.client.get(URI(string: config.baseURL + "/accounts/\(accountId)/transactions/")) {
            $0.headers.bearerAuthorization = .init(token: accessToken)
        }
        try Self.ensureOK(response, req: req, path: "/accounts/{id}/transactions/")
        return try response.content.decode(GCTransactionsResponse.self)
    }

    private static func ensureOK(_ response: ClientResponse, req: Request, path: String) throws {
        guard (200 ..< 300).contains(response.status.code) else {
            let detail = response.body.map { String(buffer: $0) } ?? ""
            req.logger.warning("GoCardless \(path) failed status=\(response.status.code) body=\(detail.prefix(300))")
            throw Abort(.badGateway, reason: "GoCardless request failed.")
        }
    }
}
