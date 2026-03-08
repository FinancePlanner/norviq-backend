@testable import StockPlanBackend
import VaporTesting
import Testing

@Suite("OpenAPI Docs Tests")
struct OpenAPIDocsTests {
    @Test("OpenAPI spec includes health and UserProfile endpoints and schemas")
    func docsAreBundled() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)

            try await app.testing().test(.GET, "openapi.yaml", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/yaml; charset=utf-8")

                let body = res.body.string
                #expect(body.contains("/health:"))
                #expect(body.contains("operationId: health"))
                #expect(body.contains("HealthResponse:"))
                #expect(body.contains("/v1/users:"))
                #expect(body.contains("operationId: getUserProfile"))
                #expect(body.contains("operationId: updateUserProfile"))
                #expect(body.contains("operationId: deleteUserProfile"))
                #expect(body.contains("UserProfile:"))
                #expect(body.contains("UpdateUserProfileRequest:"))
                #expect(body.contains("DeleteUserProfileResponse:"))
            })
        } catch {
            try await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }
}
