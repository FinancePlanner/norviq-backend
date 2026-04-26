import Fluent
import Foundation
import Vapor

enum BrokersServiceError: Error {
    case invalidProvider
    case notFound
}

extension BrokersServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .invalidProvider:
            .badRequest
        case .notFound:
            .notFound
        }
    }

    var reason: String {
        switch self {
        case .invalidProvider:
            "Invalid broker provider."
        case .notFound:
            "Broker not found."
        }
    }
}

protocol BrokersService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse]
    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
    func startIBKRConnect(redirectURI: String, portfolioListId: String?, userId: UUID, on req: Request) async throws -> BrokerConnectStartResponse
    func handleIBKRCallback(flowId: UUID, state: String, on req: Request) async throws -> Response
    func syncIBKR(userId: UUID, on req: Request) async throws -> BrokerSyncResponse
    func disconnectIBKR(userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
}

struct DefaultBrokersService: BrokersService {
    let repo: any BrokersRepository
    let ibkrGatewayClient: IBKRBrokerGatewayClient

    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse] {
        let connections = try await repo.list(userId: userId, on: db)
        return try connections.map { try BrokerConnectionResponse(from: $0) }
    }

    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        guard let connection = try await repo.find(provider: normalized, userId: userId, on: db) else {
            throw BrokersServiceError.notFound
        }
        return try BrokerConnectionResponse(from: connection)
    }

    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        let connection = try await repo.upsertCsvImport(provider: normalized, userId: userId, on: db)
        return try BrokerConnectionResponse(from: connection)
    }

    func startIBKRConnect(
        redirectURI: String,
        portfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> BrokerConnectStartResponse {
        let normalizedRedirectURI = try normalizeRedirectURI(redirectURI)
        try validateRedirectURI(normalizedRedirectURI)
        let provider = "ibkr"
        let state = randomURLSafeString(length: 32)
        let expiresIn = 600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let resolvedPortfolioListId = try await resolvePortfolioListId(
            requestedId: portfolioListId,
            userId: userId,
            on: req.db,
            defaultWhenMissing: true
        )

        let flow = BrokerOAuthFlow(
            userId: userId,
            provider: provider,
            state: state,
            redirectURI: normalizedRedirectURI,
            portfolioListId: resolvedPortfolioListId,
            expiresAt: expiresAt
        )
        try await flow.save(on: req.db)

        guard let flowID = flow.id else {
            throw Abort(.internalServerError, reason: "Broker connect flow id missing.")
        }

        let callbackURL = try makeBrokerCallbackURL(
            req: req,
            flowId: flowID,
            state: state
        )
        return BrokerConnectStartResponse(
            flowId: flowID.uuidString,
            authorizationURL: callbackURL.absoluteString,
            expiresIn: expiresIn
        )
    }

    func handleIBKRCallback(flowId: UUID, state: String, on req: Request) async throws -> Response {
        let now = Date()
        guard let flow = try await BrokerOAuthFlow.query(on: req.db)
            .filter(\.$id == flowId)
            .filter(\.$provider == "ibkr")
            .filter(\.$usedAt == nil)
            .first()
        else {
            throw Abort(.unauthorized, reason: "Broker connect flow is invalid or expired.")
        }

        guard flow.expiresAt > now else {
            throw Abort(.unauthorized, reason: "Broker connect flow expired.")
        }

        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flow.state == normalizedState else {
            throw Abort(.unauthorized, reason: "Broker connect state mismatch.")
        }

        flow.usedAt = now
        try await flow.save(on: req.db)

        do {
            let account = try await ibkrGatewayClient.requirePrimaryAccount(on: req)
            let connection = try await upsertBrokerConnection(
                provider: "ibkr",
                userId: flow.userId,
                externalId: account.externalID,
                displayName: account.displayName,
                status: "connected",
                statusDetail: nil,
                connectedAt: now,
                lastSyncedAt: nil,
                portfolioListId: flow.portfolioListId,
                on: req.db
            )

            _ = try await IBKRBrokerSyncService(gatewayClient: ibkrGatewayClient)
                .sync(connection: connection, userId: flow.userId, on: req)
            return redirectResponse(to: brokerAppRedirectURL(base: flow.redirectURI, status: "success", error: nil))
        } catch {
            _ = try? await upsertBrokerConnection(
                provider: "ibkr",
                userId: flow.userId,
                externalId: nil,
                displayName: nil,
                status: "error",
                statusDetail: brokerErrorMessage(error),
                connectedAt: nil,
                lastSyncedAt: nil,
                portfolioListId: flow.portfolioListId,
                on: req.db
            )
            return redirectResponse(
                to: brokerAppRedirectURL(
                    base: flow.redirectURI,
                    status: "error",
                    error: brokerErrorMessage(error)
                )
            )
        }
    }

    func syncIBKR(userId: UUID, on req: Request) async throws -> BrokerSyncResponse {
        guard let connection = try await repo.find(provider: "ibkr", userId: userId, on: req.db) else {
            throw BrokersServiceError.notFound
        }

        do {
            return try await IBKRBrokerSyncService(gatewayClient: ibkrGatewayClient)
                .sync(connection: connection, userId: userId, on: req)
        } catch {
            connection.status = "error"
            connection.statusDetail = brokerErrorMessage(error)
            connection.updatedAt = Date()
            try? await connection.save(on: req.db)
            throw error
        }
    }

    func disconnectIBKR(userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        guard let connection = try await repo.find(provider: "ibkr", userId: userId, on: db) else {
            throw BrokersServiceError.notFound
        }

        connection.accessToken = nil
        connection.refreshToken = nil
        connection.expiresAt = nil
        connection.status = "disconnected"
        connection.statusDetail = nil
        connection.updatedAt = Date()
        try await connection.save(on: db)
        return try BrokerConnectionResponse(from: connection)
    }
}

extension BrokerConnectionResponse {
    init(from model: BrokerConnection) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "BrokerConnection id missing")
        }

        self.init(
            id: id.uuidString,
            provider: model.provider,
            status: model.status,
            displayName: model.displayName,
            statusDetail: model.statusDetail,
            connectedAt: model.connectedAt,
            lastSyncedAt: model.lastSyncedAt,
            portfolioListId: model.portfolioListId?.uuidString
        )
    }
}

private extension DefaultBrokersService {
    func normalizeRedirectURI(_ redirectURI: String) throws -> String {
        let normalized = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              !scheme.isEmpty,
              url.host != nil || url.path.hasPrefix("/")
        else {
            throw Abort(.badRequest, reason: "Invalid broker redirect URI.")
        }
        return normalized
    }

    func validateRedirectURI(_ redirectURI: String) throws {
        let allowed = Environment.get("OAUTH_ALLOWED_REDIRECT_URIS")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        guard !allowed.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "OAuth redirect allowlist is not configured.")
        }
        guard allowed.contains(redirectURI) else {
            throw Abort(.badRequest, reason: "Broker redirect URI is not allowed.")
        }
    }

    func makeBrokerCallbackURL(req: Request, flowId: UUID, state: String) throws -> URL {
        let scheme = req.headers.first(name: "X-Forwarded-Proto") ?? "https"
        guard let host = req.headers.first(name: .host), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "Missing request host.")
        }
        guard var components = URLComponents(string: "\(scheme)://\(host)") else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        components.path = "/v1/auth/brokers/ibkr/callback"
        components.queryItems = [
            URLQueryItem(name: "flowId", value: flowId.uuidString),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Failed to build broker callback URL.")
        }
        return url
    }

    func redirectResponse(to url: URL) -> Response {
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: url.absoluteString)
        return response
    }

    func brokerAppRedirectURL(base: String, status: String, error: String?) -> URL {
        var components = URLComponents(string: base) ?? URLComponents()
        var queryItems = components.queryItems ?? []
        queryItems.append(.init(name: "broker", value: "ibkr"))
        queryItems.append(.init(name: "status", value: status))
        if let error, !error.isEmpty {
            queryItems.append(.init(name: "error", value: error))
        }
        components.queryItems = queryItems
        return components.url ?? URL(string: base)!
    }

    // swiftlint:disable:next function_parameter_count
    func upsertBrokerConnection(
        provider: String,
        userId: UUID,
        externalId: String?,
        displayName: String?,
        status: String,
        statusDetail: String?,
        connectedAt: Date?,
        lastSyncedAt: Date?,
        portfolioListId: UUID?,
        on db: any Database
    ) async throws -> BrokerConnection {
        let connection = try await repo.find(provider: provider, userId: userId, on: db)
            ?? BrokerConnection(userId: userId, provider: provider, status: status)
        connection.externalId = externalId ?? connection.externalId
        connection.displayName = displayName ?? connection.displayName
        connection.status = status
        connection.statusDetail = statusDetail
        connection.connectedAt = connectedAt ?? connection.connectedAt
        connection.lastSyncedAt = lastSyncedAt ?? connection.lastSyncedAt
        connection.portfolioListId = portfolioListId ?? connection.portfolioListId
        connection.updatedAt = Date()
        try await connection.save(on: db)
        return connection
    }

    func brokerErrorMessage(_ error: any Error) -> String {
        if let abortError = error as? any AbortError {
            return abortError.reason
        }
        return (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0 ..< length).map { _ in alphabet.randomElement()! })
    }
}
