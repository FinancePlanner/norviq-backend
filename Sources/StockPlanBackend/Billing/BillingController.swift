import StockPlanShared
import Vapor

struct BillingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let billing = protected.grouped("billing")

        billing.get("me", use: me)
    }

    @Sendable
    func me(req: Request) async throws -> BillingContextResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.billingContextService.context(userId: session.userId, on: req.db)
    }
}
