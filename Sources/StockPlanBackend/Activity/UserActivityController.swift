import Vapor
import StockPlanShared

struct UserActivityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let activities = routes.grouped("activities")
        let protected = activities.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())

        protected.get(use: getActivities)
    }

    @Sendable
    func getActivities(req: Request) async throws -> [UserActivityResponse] {
        let session = try req.auth.require(SessionToken.self)
        let limit = req.query[Int.self, at: "limit"] ?? 20

        return try await req.userActivityService.getActivities(userId: session.userId, limit: limit, on: req.db)
    }
}
