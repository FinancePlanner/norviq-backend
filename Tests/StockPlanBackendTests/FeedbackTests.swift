import Foundation
@testable import StockPlanBackend
import Testing
import VaporTesting

@Suite("Feedback Tests", .serialized)
struct FeedbackTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "feedback_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "feedback+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?

        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        return try #require(response)
    }

    @Test("Authenticated users can submit feedback")
    func authenticatedFeedbackSubmissionSucceeds() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "success")

            try await app.testing().test(.POST, "v1/feedback", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(FeedbackRequest(topic: "General Feedback", message: "The settings screen is clearer."))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(FeedbackResponse.self)
                #expect(response.success)
            })
        }
    }

    @Test("Feedback requires authentication")
    func feedbackRequiresAuthentication() async throws {
        try await withApp { app in
            try await app.testing().test(.POST, "v1/feedback", beforeRequest: { req in
                try req.content.encode(FeedbackRequest(topic: "General Feedback", message: "Unauthenticated"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Feedback rejects empty fields")
    func feedbackRejectsEmptyFields() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "empty")

            try await app.testing().test(.POST, "v1/feedback", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(FeedbackRequest(topic: " ", message: " "))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
}
