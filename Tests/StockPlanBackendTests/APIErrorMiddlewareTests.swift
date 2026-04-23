@testable import StockPlanBackend
import Vapor
import VaporTesting
import Testing

@Suite("API Error Middleware Tests")
struct APIErrorMiddlewareTests {
    @Test("Abort errors return the standard API error envelope")
    func abortErrorsUseStandardEnvelope() async throws {
        let app = try await Application.make(.testing)
        app.middleware = .init()
        app.middleware.use(APIErrorMiddleware())
        app.get("bad-request") { _ async throws -> String in
            throw Abort(.badRequest, reason: "Symbol is required.")
        }

        try await app.testing().test(.GET, "bad-request", afterResponse: { res async throws in
            #expect(res.status == .badRequest)
            let body = try res.content.decode(APIErrorEnvelope.self)
            #expect(body.error == true)
            #expect(body.code == "bad_request")
            #expect(body.reason == "Symbol is required.")
        })

        try await app.asyncShutdown()
    }

    @Test("Unexpected errors do not expose internals in production")
    func productionUnexpectedErrorsUseSafeReason() async throws {
        let app = try await Application.make(.production)
        app.middleware = .init()
        app.middleware.use(APIErrorMiddleware())
        app.get("boom") { _ async throws -> String in
            throw ExampleFailure()
        }

        try await app.testing().test(.GET, "boom", afterResponse: { res async throws in
            #expect(res.status == .internalServerError)
            let body = try res.content.decode(APIErrorEnvelope.self)
            #expect(body.code == "internal_server_error")
            #expect(body.reason == "Internal Server Error")
        })

        try await app.asyncShutdown()
    }

    private struct ExampleFailure: Error {}
}
