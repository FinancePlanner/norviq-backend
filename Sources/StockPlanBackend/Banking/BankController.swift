import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Read-only bank sync: connect a bank, review synced transactions, and import
/// the ones the user confirms as expenses. All connect/sync operations require
/// the `bankSync` entitlement.
struct BankController: RouteCollection {
    private let importService = BankTransactionImportService()

    func boot(routes: any RoutesBuilder) throws {
        let banks = routes.grouped("banks")
        let protected = banks.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        // bank:read predates the per-domain split and is still honoured here so
        // tokens minted against it keep reading bank data without re-issue.
        let read = protected.grouped(ScopeRequirementMiddleware(anyOf: [.integrationsRead, .bankRead]))
        let write = protected.grouped(ScopeRequirementMiddleware(.integrationsWrite))

        read.get("institutions", use: listInstitutions)
        write.post("link-session", use: createLinkSession)
        write.post("connections", use: exchange)
        read.get("connections", use: listConnections)
        write.delete("connections", ":id", use: disconnect)
        write.post("connections", ":id", "sync", use: syncConnection)
        read.get("transactions", use: listTransactions)
        write.post("transactions", ":id", "import", use: importTransaction)
        write.post("transactions", ":id", "dismiss", use: dismissTransaction)
    }

    // MARK: - Connections

    @Sendable
    func listInstitutions(req: Request) async throws -> [BankInstitutionResponse] {
        _ = try req.auth.require(SessionToken.self)
        let country = req.query[String.self, at: "country"] ?? "GB"
        let provider = try req.bankProviderRegistry.provider(for: providerKind(req, hosted: true))
        return try await provider.listInstitutions(country: country, on: req)
    }

    @Sendable
    func createLinkSession(req: Request) async throws -> BankLinkSessionResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.bankSync, userId: session.userId, on: req.db)
        // Hosted providers need an institution + redirect; Plaid returns a link
        // token with no prior selection.
        let hosted = (try? req.content.decode(BankHostedLinkRequest.self)).flatMap { $0.institutionId.isEmpty ? nil : $0 }
        let provider = try req.bankProviderRegistry.provider(for: providerKind(req, hosted: hosted != nil))

        if let hosted {
            try Self.validateRedirectURI(hosted.redirectURI)
            return try await provider.createHostedLink(
                userId: session.userId,
                institutionId: hosted.institutionId,
                redirectURI: hosted.redirectURI,
                on: req
            )
        }
        return try await provider.createLinkSession(userId: session.userId, on: req)
    }

    @Sendable
    func exchange(req: Request) async throws -> BankConnectionResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.bankSync, userId: session.userId, on: req.db)
        let request = try req.content.decode(BankExchangeRequest.self)
        let provider = try req.bankProviderRegistry.provider(for: providerKind(req))

        let connection = try await provider.exchange(request, userId: session.userId, on: req)
        // Kick an initial sync so the user immediately sees suggestions.
        _ = try? await provider.sync(connection: connection, on: req)
        let accounts = try await accounts(for: connection, on: req.db)
        return try BankConnectionResponse(from: connection, accounts: accounts)
    }

    @Sendable
    func listConnections(req: Request) async throws -> [BankConnectionResponse] {
        let session = try req.auth.require(SessionToken.self)
        let connections = try await BankConnection.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()
        var result: [BankConnectionResponse] = []
        for connection in connections {
            let accounts = try await accounts(for: connection, on: req.db)
            try result.append(BankConnectionResponse(from: connection, accounts: accounts))
        }
        return result
    }

    @Sendable
    func disconnect(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let connection = try await requireConnection(req, userId: session.userId)
        await BankConnectionRevoker.revoke(connection, on: req)
        try await connection.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func syncConnection(req: Request) async throws -> BankSyncResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.bankSync, userId: session.userId, on: req.db)
        let connection = try await requireConnection(req, userId: session.userId)
        let provider = try req.bankProviderRegistry.provider(for: BankProviderKind(rawValue: connection.provider) ?? .plaid)
        let result = try await provider.sync(connection: connection, on: req)
        return BankSyncResponse(added: result.added, modified: result.modified, removed: result.removed)
    }

    // MARK: - Transactions

    @Sendable
    func listTransactions(req: Request) async throws -> [BankTransactionResponse] {
        let session = try req.auth.require(SessionToken.self)
        let status = req.query[String.self, at: "status"] ?? BankTransactionStatus.suggested.rawValue
        let transactions = try await BankTransaction.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$status == status)
            .sort(\.$occurredOn, .descending)
            .all()

        let duplicates = try await importService.markDuplicates(transactions, userId: session.userId, on: req.db)
        return try transactions.map { try BankTransactionResponse(from: $0, possibleDuplicate: duplicates.contains($0.id ?? UUID())) }
    }

    @Sendable
    func importTransaction(req: Request) async throws -> ExpenseResponse {
        let session = try req.auth.require(SessionToken.self)
        let transaction = try await requireTransaction(req, userId: session.userId)
        guard transaction.status == BankTransactionStatus.suggested.rawValue else {
            throw Abort(.conflict, reason: "Transaction is not awaiting review.")
        }
        let request = try req.content.decode(BankTransactionImportRequest.self)
        return try await importService.importTransaction(transaction, request: request, userId: session.userId, on: req)
    }

    @Sendable
    func dismissTransaction(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let transaction = try await requireTransaction(req, userId: session.userId)
        transaction.status = BankTransactionStatus.dismissed.rawValue
        try await transaction.save(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    /// An explicit `provider` query wins. Otherwise hosted-link calls go to the
    /// configured EU aggregator and the rest to Plaid, so clients need not name
    /// a vendor.
    private func providerKind(_ req: Request, hosted: Bool = false) throws -> BankProviderKind {
        guard let raw = req.query[String.self, at: "provider"] else {
            return hosted ? req.bankProviderRegistry.preferredHostedKind : .plaid
        }
        guard let kind = BankProviderKind(rawValue: raw.lowercased()) else {
            throw Abort(.badRequest, reason: "Unknown bank provider.")
        }
        return kind
    }

    /// The callback 303s to this URI with the outcome, so it must be one of
    /// ours: an unchecked value would make the callback an open redirect.
    static func validateRedirectURI(
        _ redirectURI: String,
        allowList: String? = Environment.get("BANK_ALLOWED_REDIRECT_URIS")
    ) throws {
        let allowed = (allowList ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !allowed.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Bank redirect allowlist is not configured.")
        }
        guard allowed.contains(redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Abort(.badRequest, reason: "Bank redirect URI is not allowed.")
        }
    }

    private func requireConnection(_ req: Request, userId: UUID) async throws -> BankConnection {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing connection id.")
        }
        guard let connection = try await BankConnection.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Bank connection not found.")
        }
        return connection
    }

    private func requireTransaction(_ req: Request, userId: UUID) async throws -> BankTransaction {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing transaction id.")
        }
        guard let transaction = try await BankTransaction.query(on: req.db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Transaction not found.")
        }
        return transaction
    }

    private func accounts(for connection: BankConnection, on db: any Database) async throws -> [BankAccount] {
        guard let connectionId = connection.id else { return [] }
        return try await BankAccount.query(on: db)
            .filter(\.$connectionId == connectionId)
            .all()
    }
}
