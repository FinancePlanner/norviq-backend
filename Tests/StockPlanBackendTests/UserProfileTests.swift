@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import Foundation

@Suite("User Profile Tests", .serialized)
struct UserProfileTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
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

    private func makeRegisterRequest(
        email: String,
        password: String = "Password123",
        username: String = "valid_user",
        firstName: String = "Test",
        lastName: String = "User",
        dateOfBirth: Date = Date(timeIntervalSince1970: 946_684_800)
    ) -> AuthRegisterRequest {
        AuthRegisterRequest(
            username: username,
            password: password,
            email: email,
            firstName: firstName,
            lastName: lastName,
            dateOfBirth: dateOfBirth
        )
    }

    private func registerUser(
        on app: Application,
        email: String,
        username: String = "valid_user"
    ) async throws -> AuthResponse {
        let request = makeRegisterRequest(email: email, username: username)
        var response: AuthResponse?

        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        return try #require(response)
    }

    @Test("Get user profile returns authenticated user fields")
    func getUserProfile() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "profile@example.com", username: "profile_user")

            try await app.testing().test(.GET, "user-profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(GetUserProfileResponse.self)
                #expect(response.userProfile.id == auth.userId.uuidString)
                #expect(response.userProfile.email == "profile@example.com")
                #expect(response.userProfile.username == "profile_user")
                #expect(response.userProfile.firstName == "Test")
                #expect(response.userProfile.lastName == "User")
            })
        }
    }

    @Test("Update user profile persists profile fields")
    func updateUserProfile() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "update-profile@example.com", username: "update_user")
            let payload = UpdateUserProfileRequest(
                userProfile: UserProfile(
                    id: auth.userId.uuidString,
                    email: "updated@example.com",
                    bio: "Focused on long-term compounding",
                    avatarURL: URL(string: "https://example.com/avatar.png"),
                    bannerAvatarURL: URL(string: "https://example.com/banner.png"),
                    username: "updated_user",
                    firstName: "Jane",
                    lastName: "Investor"
                )
            )

            try await app.testing().test(.PUT, "user-profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(UpdateUserProfileResponse.self)
                #expect(response.userProfile.email == "updated@example.com")
                #expect(response.userProfile.bio == "Focused on long-term compounding")
                #expect(response.userProfile.username == "updated_user")
                #expect(response.userProfile.firstName == "Jane")
                #expect(response.userProfile.lastName == "Investor")
                #expect(response.userProfile.avatarURL == URL(string: "https://example.com/avatar.png"))
                #expect(response.userProfile.bannerAvatarURL == URL(string: "https://example.com/banner.png"))
            })
        }
    }

    @Test("Delete user profile deletes the account")
    func deleteUserProfile() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "delete-profile@example.com", username: "delete_user")

            try await app.testing().test(.DELETE, "user-profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(DeleteUserProfileResponse.self)
                #expect(response.success)
            })

            let deletedUser = try await User.find(auth.userId, on: app.db)
            #expect(deletedUser == nil)

            try await app.testing().test(.GET, "user-profile", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }
}
