import Vapor

struct DashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.get("dashboard", use: dashboard)
    }

    @Sendable
    func dashboard(req: Request) async throws -> DashboardResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.dashboardService.dashboard(userId: session.userId, on: req.db)
    }
}
