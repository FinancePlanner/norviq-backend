import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("User Profile Tests", .serialized)
struct UserProfileTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
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
        password: String = "Password123!",
        username: String = "valid_user",
        dateOfBirth: Date = Date(timeIntervalSince1970: 946_684_800)
    ) -> AuthRegisterRequest {
        AuthRegisterRequest(
            username: username,
            password: password,
            confirmPassword: password,
            email: email,
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
                    email: "update-profile@example.com",
                    bio: "Focused on long-term compounding",
                    avatarURL: URL(string: "https://example.com/avatar.png"),
                    bannerAvatarURL: URL(string: "https://example.com/banner.png"),
                    username: "updated_user"
                )
            )

            try await app.testing().test(.PUT, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(UpdateUserProfileResponse.self)
                #expect(response.userProfile.email == "update-profile@example.com")
                #expect(response.userProfile.bio == "Focused on long-term compounding")
                #expect(response.userProfile.username == "updated_user")
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
                    email: "update-profile-id@example.com",
                    bio: "Updated through path id",
                    avatarURL: URL(string: "https://example.com/avatar-id.png"),
                    bannerAvatarURL: URL(string: "https://example.com/banner-id.png"),
                    username: "updated_user_id"
                )
            )

            try await app.testing().test(.PUT, "v1/users/\(auth.userId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(UpdateUserProfileResponse.self)
                #expect(response.userProfile.email == "update-profile-id@example.com")
                #expect(response.userProfile.bio == "Updated through path id")
                #expect(response.userProfile.username == "updated_user_id")
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

    // MARK: - Email change re-authentication

    private struct EmailChangeBody: Content {
        var email: String
        var currentPassword: String?
        var refreshToken: String?
    }

    private func send(
        _ app: Application,
        _ method: HTTPMethod,
        _ path: String,
        token: String,
        body: (some Content)?
    ) async throws -> (status: HTTPStatus, reason: String?) {
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            if let body { try req.content.encode(body) }
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(APIErrorEnvelope.self).reason)
        })
        return result
    }

    private func refreshStatus(_ app: Application, _ refreshToken: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(.POST, "v1/auth/refresh", beforeRequest: { req in
            try req.content.encode(AuthRefreshRequest(refreshToken: refreshToken))
        }, afterResponse: { res async in
            status = res.status
        })
        return status
    }

    @Test("Email change through PUT /v1/users is refused; it needs re-authentication")
    func putCannotChangeEmail() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "put-email@example.com", username: "put_email")
            let payload = UpdateUserProfileRequest(
                userProfile: UserProfile(
                    id: auth.userId.uuidString, email: "attacker@example.com", bio: nil,
                    avatarURL: nil, bannerAvatarURL: nil, username: "put_email"
                )
            )
            let result = try await send(app, .PUT, "v1/users", token: auth.token, body: payload)
            #expect(result.status == .badRequest)
            #expect(result.reason == "EMAIL_CHANGE_REQUIRES_REAUTH")
            #expect(try await User.find(auth.userId, on: app.db)?.email == "put-email@example.com")
        }
    }

    @Test("Email change requires the current password")
    func emailChangeRequiresCurrentPassword() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "reauth@example.com", username: "reauth_user")

            let missing = try await send(app, .PATCH, "v1/users/email", token: auth.token,
                                         body: EmailChangeBody(email: "new@example.com"))
            #expect(missing.status == .badRequest)
            #expect(missing.reason == "CURRENT_PASSWORD_REQUIRED")

            let wrong = try await send(app, .PATCH, "v1/users/email", token: auth.token,
                                       body: EmailChangeBody(email: "new@example.com", currentPassword: "Wrong123!"))
            // 400, not 401: clients read 401 as an expired session.
            #expect(wrong.status == .badRequest)
            #expect(wrong.reason == "INVALID_CURRENT_PASSWORD")
            #expect(try await User.find(auth.userId, on: app.db)?.email == "reauth@example.com")

            let unchanged = try await send(app, .PATCH, "v1/users/email", token: auth.token, body: EmailChangeBody(
                email: " Reauth@Example.com ", currentPassword: "Password123!", refreshToken: auth.refreshToken
            ))
            #expect(unchanged.status == .badRequest)
            #expect(unchanged.reason == "EMAIL_UNCHANGED")
            // Nothing was revoked.
            #expect(try await refreshStatus(app, auth.refreshToken) == .ok)
        }
    }

    @Test("Email change with the password unverifies the address and ends every other session")
    func emailChangeRevokesOtherSessions() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "mover@example.com", username: "mover_user")
            // A second device's session.
            var other: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(AuthLoginRequest(email: "mover@example.com", password: "Password123!"))
            }, afterResponse: { res async throws in
                other = try res.content.decode(AuthResponse.self)
            })
            let otherSession = try #require(other)
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.emailVerifiedAt = Date()
            try await user.save(on: app.db)

            let result = try await send(app, .PATCH, "v1/users/email", token: auth.token, body: EmailChangeBody(
                email: "Moved@Example.com", currentPassword: "Password123!", refreshToken: auth.refreshToken
            ))
            #expect(result.status == .ok)

            let moved = try #require(try await User.find(auth.userId, on: app.db))
            #expect(moved.email == "moved@example.com")
            #expect(moved.emailVerifiedAt == nil)
            #expect(try await refreshStatus(app, otherSession.refreshToken) == .unauthorized)
            #expect(try await refreshStatus(app, auth.refreshToken) == .ok)
            // The caller's own access token survives its own change.
            try await app.testing().test(.GET, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("OAuth-only accounts cannot re-authenticate by password: 409 REAUTH_REQUIRED")
    func emailChangeForOAuthOnlyAccount() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "oauth-only@example.com", username: "oauth_only")
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.passwordSetAt = nil
            try await user.save(on: app.db)

            let result = try await send(app, .PATCH, "v1/users/email", token: auth.token,
                                        body: EmailChangeBody(email: "elsewhere@example.com", currentPassword: "guess"))
            #expect(result.status == .conflict)
            #expect(result.reason == "REAUTH_REQUIRED")
        }
    }

    @Test("A wrong current password on password change is a 400, never a session-ending 401")
    func passwordChangeWrongCurrentPassword() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "pw-typo@example.com", username: "pw_typo")
            let result = try await send(app, .PATCH, "v1/users/password", token: auth.token, body: UpdatePasswordRequest(
                currentPassword: "Wrong123!", newPassword: "NewPassword123!"
            ))
            #expect(result.status == .badRequest)
            #expect(result.reason == "INVALID_CURRENT_PASSWORD")
            #expect(try await refreshStatus(app, auth.refreshToken) == .ok)
        }
    }

    @Test("Password change ends every other session but keeps the caller's")
    func passwordChangeRevokesOtherSessions() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, email: "pw-change@example.com", username: "pw_change")
            var other: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(AuthLoginRequest(email: "pw-change@example.com", password: "Password123!"))
            }, afterResponse: { res async throws in
                other = try res.content.decode(AuthResponse.self)
            })
            let otherSession = try #require(other)

            struct Body: Content {
                let currentPassword: String
                let newPassword: String
                let refreshToken: String
            }
            let result = try await send(app, .PATCH, "v1/users/password", token: auth.token, body: Body(
                currentPassword: "Password123!", newPassword: "NewPassword123!", refreshToken: auth.refreshToken
            ))
            #expect(result.status == .ok)
            #expect(try await refreshStatus(app, otherSession.refreshToken) == .unauthorized)
            #expect(try await refreshStatus(app, auth.refreshToken) == .ok)
        }
    }

    // MARK: - Account deletion completeness

    @Test("Deleting an account takes feedback, snapshots and the loss ledger with it, and revokes bank links")
    func deleteRemovesOwnedRowsAndRevokesBankLinks() async throws {
        try await withApp { app in
            let revoked = RevokedConnections()
            app.bankProviderRegistry = BankProviderRegistry(providers: [
                RecordingBankProvider(kind: .plaid, revoked: revoked, fails: false),
                RecordingBankProvider(kind: .gocardless, revoked: revoked, fails: true),
            ])
            let auth = try await registerUser(on: app, email: "leaving@example.com", username: "leaving_user")
            let userId = auth.userId

            try await Feedback(topic: "bug", message: "it broke", userID: userId).save(on: app.db)
            try await PortfolioValueSnapshot(
                userId: userId, portfolioListId: UUID(), capturedOn: Date(), currency: "EUR",
                marketValue: 100, costBasis: 90, cashBalance: 0, positionCount: 1,
                source: .live, pricedSymbols: 1, missingSymbols: 0
            ).save(on: app.db)
            let carryforward = TaxLossCarryforward()
            carryforward.userId = userId
            carryforward.jurisdiction = "PT"
            carryforward.sourceTaxYear = 2025
            carryforward.expiresAfterTaxYear = 2030
            carryforward.originalAmount = 10
            carryforward.remainingAmount = 10
            carryforward.currency = "EUR"
            carryforward.ruleVersion = "test"
            try await carryforward.save(on: app.db)
            let plaidLink = BankConnection(userId: userId, provider: "plaid", providerItemId: "item-1", status: "active")
            try await plaidLink.save(on: app.db)
            // GoCardless refuses: deletion must still go through.
            let gcLink = BankConnection(userId: userId, provider: "gocardless", providerItemId: "req-1", status: "active")
            try await gcLink.save(on: app.db)

            try await app.testing().test(.DELETE, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            #expect(try await User.find(userId, on: app.db) == nil)
            #expect(try await Feedback.query(on: app.db).filter(\.$user.$id == userId).count() == 0)
            #expect(try await PortfolioValueSnapshot.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await TaxLossCarryforward.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await BankConnection.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(await revoked.itemIds.sorted() == ["item-1", "req-1"])
        }
    }

    @Test("A hung bank provider cannot hold a revocation past its deadline")
    func bankRevocationTimesOut() async throws {
        try await withApp { app in
            let revoked = RevokedConnections()
            app.bankProviderRegistry = BankProviderRegistry(providers: [
                RecordingBankProvider(kind: .plaid, revoked: revoked, fails: false, delay: .seconds(3)),
            ])
            let link = BankConnection(userId: UUID(), provider: "plaid", providerItemId: "slow", status: "active")
            let clock = ContinuousClock()
            let started = clock.now
            await BankConnectionRevoker.revoke(link, on: Request(application: app, on: app.eventLoopGroup.next()),
                                               timeout: .milliseconds(200))
            #expect(clock.now - started < .seconds(2))
        }
    }
}

private actor RevokedConnections {
    var itemIds: [String] = []
    func append(_ id: String) {
        itemIds.append(id)
    }
}

/// Records each revocation; `fails` simulates a provider outage.
private struct RecordingBankProvider: BankProvider {
    let kind: BankProviderKind
    let revoked: RevokedConnections
    let fails: Bool
    var delay: Duration = .zero

    func createLinkSession(userId _: UUID, on _: Request) async throws -> BankLinkSessionResponse {
        throw BankProviderError.unsupportedOperation
    }

    func exchange(_: BankExchangeRequest, userId _: UUID, on _: Request) async throws -> BankConnection {
        throw BankProviderError.unsupportedOperation
    }

    func sync(connection _: BankConnection, on _: Request) async throws -> BankSyncResult {
        BankSyncResult()
    }

    func disconnect(connection: BankConnection, on _: Request) async throws {
        await revoked.append(connection.providerItemId)
        if delay > .zero {
            // Ignores cancellation on purpose, like an HTTP call that hangs.
            let seconds = Double(delay.components.seconds)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
            }
        }
        if fails {
            throw Abort(.badGateway, reason: "provider down")
        }
    }
}
