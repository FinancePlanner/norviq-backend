import StockPlanShared
import Vapor

struct DashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("dashboard", use: dashboard)
        protected.get("dashboard", "insights", use: insights)
    }

    @Sendable
    func dashboard(req: Request) async throws -> DashboardResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.dashboardService.dashboard(userId: session.userId, req: req, on: req.db)
    }

    @Sendable
    func insights(req: Request) async throws -> DashboardInsightsResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.dashboardService.insights(userId: session.userId, req: req, on: req.db)
    }
}
