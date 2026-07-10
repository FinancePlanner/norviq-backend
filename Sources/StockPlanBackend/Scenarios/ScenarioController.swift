import Vapor

struct ScenarioController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.group("scenarios") { scenarios in
            scenarios.get("catalog", use: catalog)
        }
    }

    @Sendable
    func catalog(req: Request) async throws -> ScenarioCatalogResponse {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else {
            throw Abort(.notFound)
        }
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(
            .scenarioPlanning,
            userId: session.userId,
            on: req.db
        )
        return ScenarioCatalog.response
    }
}
