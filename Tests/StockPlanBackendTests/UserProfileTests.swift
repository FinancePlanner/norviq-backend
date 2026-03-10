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

        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
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

            try await app.testing().test(.GET, "v1/users", beforeRequest: { req in
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

    @Test("Get user profile by id returns authenticated user fields when path id matches token")
    func getUserProfileByID() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "profile-by-id@example.com", username: "profile_by_id")

            try await app.testing().test(.GET, "v1/users/\(auth.userId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(GetUserProfileResponse.self)
                #expect(response.userProfile.id == auth.userId.uuidString)
                #expect(response.userProfile.email == "profile-by-id@example.com")
                #expect(response.userProfile.username == "profile_by_id")
            })
        }
    }

    @Test("Get user profile by id is forbidden when path id does not match authenticated user")
    func getUserProfileByIDForbiddenForDifferentUser() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "profile-owner@example.com", username: "profile_owner")
            let other = try await registerUser(on: app, email: "other-profile@example.com", username: "other_profile")

            try await app.testing().test(.GET, "v1/users/\(other.userId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
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

            try await app.testing().test(.PUT, "v1/users", beforeRequest: { req in
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

    @Test("Update user profile by id persists profile fields")
    func updateUserProfileByID() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "update-profile-id@example.com", username: "update_user_id")
            let payload = UpdateUserProfileRequest(
                userProfile: UserProfile(
                    id: auth.userId.uuidString,
                    email: "updated-by-id@example.com",
                    bio: "Updated through path id",
                    avatarURL: URL(string: "https://example.com/avatar-id.png"),
                    bannerAvatarURL: URL(string: "https://example.com/banner-id.png"),
                    username: "updated_user_id",
                    firstName: "Janet",
                    lastName: "Investor"
                )
            )

            try await app.testing().test(.PUT, "v1/users/\(auth.userId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(UpdateUserProfileResponse.self)
                #expect(response.userProfile.email == "updated-by-id@example.com")
                #expect(response.userProfile.bio == "Updated through path id")
                #expect(response.userProfile.username == "updated_user_id")
                #expect(response.userProfile.firstName == "Janet")
                #expect(response.userProfile.lastName == "Investor")
            })
        }
    }

    @Test("Delete user profile deletes the account")
    func deleteUserProfile() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "delete-profile@example.com", username: "delete_user")

            try await app.testing().test(.DELETE, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(DeleteUserProfileResponse.self)
                #expect(response.success)
            })

            let deletedUser = try await User.find(auth.userId, on: app.db)
            #expect(deletedUser == nil)

            try await app.testing().test(.GET, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Delete user profile by id deletes the account")
    func deleteUserProfileByID() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "delete-profile-id@example.com", username: "delete_user_id")

            try await app.testing().test(.DELETE, "v1/users/\(auth.userId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(DeleteUserProfileResponse.self)
                #expect(response.success)
            })

            let deletedUser = try await User.find(auth.userId, on: app.db)
            #expect(deletedUser == nil)
        }
    }
}
