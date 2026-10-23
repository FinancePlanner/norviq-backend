import Foundation
import StockPlanShared
import Vapor

extension RecapListResponse: @retroactive Content {}
extension RecapResponse: @retroactive Content {}

/// Answers 404 for every request while `RECAP_ENABLED` is off. It runs ahead
/// of authentication, so a disabled feature answers 404 rather than 401 or 403.
struct RecapEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard RecapConfig.fromEnvironment().enabled else { throw Abort(.notFound) }
        return try await next.respond(to: request)
    }
}

/// `/v1/recaps`. Every route answers 404 while `RECAP_ENABLED` is off, with or
/// without a token, so a disabled feature leaks nothing. The flags are read
/// per request.
struct RecapController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let recaps = routes.grouped("recaps")
            .grouped(RecapEnabledMiddleware(), ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = recaps.grouped(ScopeRequirementMiddleware(.planningRead))
        let write = recaps.grouped(ScopeRequirementMiddleware(.planningWrite))
        read.get(use: list)
        read.get(":kind", ":key", use: show)
        write.post(":id", "opened", use: opened)
        write.post(":id", "completed", use: completed)
    }

    private func service(_ req: Request) throws -> RecapService {
        let config = RecapConfig.fromEnvironment()
        guard config.enabled else { throw Abort(.notFound) }
        return RecapService(repository: req.application.recapRepository, config: config)
    }

    private func userId(_ req: Request) throws -> UUID {
        try req.auth.require(SessionToken.self).userId
    }

    private func recapId(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    @Sendable
    func list(req: Request) async throws -> RecapListResponse {
        let service = try service(req)
        return try await service.list(userId: userId(req), now: Date(), on: req.db)
    }

    @Sendable
    func show(req: Request) async throws -> RecapResponse {
        let service = try service(req)
        guard let kind = req.parameters.get("kind"), let key = req.parameters.get("key"),
              let period = RecapPeriod.parse(kind: kind, key: key),
              let response = try await service.recap(userId: userId(req), period: period, now: Date(), on: req.db)
        else { throw Abort(.notFound) }
        return response
    }

    @Sendable
    func opened(req: Request) async throws -> HTTPStatus {
        let service = try service(req)
        let id = try recapId(req)
        let user = try userId(req)
        guard try await service.markOpened(id: id, userId: user, now: Date(), on: req.db) else {
            throw Abort(.notFound)
        }
        req.scheduleAchievementCheck(for: user)
        return .noContent
    }

    @Sendable
    func completed(req: Request) async throws -> HTTPStatus {
        let service = try service(req)
        let id = try recapId(req)
        guard try await service.markCompleted(id: id, userId: userId(req), now: Date(), on: req.db) else {
            throw Abort(.notFound)
        }
        return .noContent
    }
}
