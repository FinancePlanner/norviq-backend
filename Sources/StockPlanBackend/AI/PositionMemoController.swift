import Fluent
import Foundation
import StockPlanShared
import Vapor

extension AIAssistantController {
    @Sendable func listMemos(req: Request) async throws -> Response {
        let userId = try await requireMemoAccess(req)
        let bookmarked = req.query[Bool.self, at: "bookmarked"]
        let conversationId = req.query[UUID.self, at: "conversationId"]
        let items = try await PositionMemoService.list(
            userId: userId, bookmarked: bookmarked, conversationId: conversationId, on: req
        )
        return try json(items)
    }

    @Sendable func getMemo(req: Request) async throws -> Response {
        let userId = try await requireMemoAccess(req)
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let detail = try await PositionMemoService.detail(id: id, userId: userId, on: req)
        return try json(detail)
    }

    @Sendable func bookmarkMemo(req: Request) async throws -> Response {
        let userId = try await requireMemoAccess(req)
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let body = try req.content.decode(PositionMemoBookmarkRequest.self)
        let card = try await PositionMemoService.setBookmarked(id: id, userId: userId, bookmarked: body.bookmarked, on: req)
        return try json(card)
    }

    @Sendable func deleteMemo(req: Request) async throws -> HTTPStatus {
        let userId = try await requireMemoAccess(req)
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        try await PositionMemoService.delete(id: id, userId: userId, on: req)
        return .noContent
    }

    private func requireMemoAccess(_ req: Request) async throws -> UUID {
        let userId = try req.auth.require(SessionToken.self).userId
        try await req.usageCounterService.requirePremium(.aiInsights, userId: userId, on: req.db)
        return userId
    }
}
