import Vapor

struct EarningsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        
        // This makes it /v1/earnings (when registered in api group)
        let earnings = protected.grouped("earnings")
        earnings.get(use: getCalendar)
    }

    @Sendable
    func getCalendar(req: Request) async throws -> [EarningsItemResponse] {
        let query = try req.query.decode(EarningsQueryRequest.self)
        return try await req.application.earningsService.getCalendar(query: query, on: req)
    }
}
