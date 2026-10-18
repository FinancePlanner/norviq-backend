import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol UserProfileService: Sendable {
    func get(userId: UUID, on db: any Database) async throws -> GetUserProfileResponse
    func update(userId: UUID, payload: UpdateUserProfileRequest, on db: any Database) async throws -> UpdateUserProfileResponse
    func updateUsername(userId: UUID, payload: UpdateUsernameRequest, on db: any Database) async throws -> UpdateUserProfileResponse
    func updateEmail(userId: UUID, payload: UpdateEmailWithReauthRequest, on req: Request) async throws -> UpdateUserProfileResponse
    func updatePassword(userId: UUID, payload: UpdatePasswordRequest, callerRefreshToken: String?, on req: Request) async throws
    func delete(userId: UUID, on req: Request) async throws -> DeleteUserProfileResponse
}

struct DefaultUserProfileService: UserProfileService {
    let repo: any UserProfileRepository

    func get(userId: UUID, on db: any Database) async throws -> GetUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        return GetUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func update(userId: UUID, payload: UpdateUserProfileRequest, on db: any Database) async throws -> UpdateUserProfileResponse {
        guard payload.userProfile.id == userId.uuidString else {
            throw Abort(.badRequest, reason: "Profile ID does not match authenticated user")
        }

        let user = try await requireUser(id: userId, on: db)
        let normalizedEmail = normalizeEmail(payload.userProfile.email)
        let normalizedUsername = normalizeOptional(payload.userProfile.username)?.lowercased()
        let normalizedBio = normalizeOptional(payload.userProfile.bio)

        try validateEmail(normalizedEmail)
        try validateUsername(normalizedUsername)

        // The email is a credential (password reset, OAuth linking, admin
        // checks used to key on it). It only changes through PATCH /v1/users/email,
        // which re-authenticates; this route cannot carry a password.
        guard normalizedEmail == normalizeEmail(user.email) else {
            throw Abort(.badRequest, reason: "EMAIL_CHANGE_REQUIRES_REAUTH")
        }

        if let normalizedUsername,
           let existing = try await repo.find(username: normalizedUsername, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Username already registered")
        }

        user.username = normalizedUsername
        user.bio = normalizedBio
        user.avatarURLString = payload.userProfile.avatarURL?.absoluteString
        user.bannerAvatarURLString = payload.userProfile.bannerAvatarURL?.absoluteString

        try await repo.save(user, on: db)
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func delete(userId: UUID, on req: Request) async throws -> DeleteUserProfileResponse {
        let user = try await requireUser(id: userId, on: req.db)

        // Revoke the aggregators' access before the rows that hold their
        // tokens cascade away. Best-effort: a provider outage must not keep an
        // account alive, so failures are logged inside the revoker.
        let bankConnections = try await BankConnection.query(on: req.db)
            .filter(\.$userId == userId)
            .all()
        for connection in bankConnections {
            await BankConnectionRevoker.revoke(connection, on: req)
        }
        // Export files sit on disk outside the database; the rows cascade,
        // the files would not.
        for export in try await DataExport.query(on: req.db).filter(\.$userId == userId).all()
            where !DatabaseDataExportRepository.removeFile(at: export.filePath)
        {
            req.logger.warning("user.delete export_file_not_removed export_id=\(export.id?.uuidString ?? "unknown")")
        }
        // Sign in with Apple: no Apple refresh token is ever stored (only the
        // identity from the id_token), so there is nothing to revoke at Apple.

        try await repo.delete(user, on: req.db)
        return DeleteUserProfileResponse(success: true, message: "User account deleted")
    }

    func updateUsername(userId: UUID, payload: UpdateUsernameRequest, on db: any Database) async throws -> UpdateUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        let normalizedUsername = normalizeOptional(payload.username)?.lowercased()
        try validateUsername(normalizedUsername)

        if let normalizedUsername,
           let existing = try await repo.find(username: normalizedUsername, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Username already registered")
        }

        user.username = normalizedUsername
        try await repo.save(user, on: db)
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    /// Changing the email moves the account: password reset and OAuth sign-in
    /// both follow it. So the caller must prove they hold the password, the
    /// new address starts unverified, and every other session ends.
    func updateEmail(userId: UUID, payload: UpdateEmailWithReauthRequest, on req: Request) async throws -> UpdateUserProfileResponse {
        let db = req.db
        let user = try await requireUser(id: userId, on: db)
        let normalizedEmail = normalizeEmail(payload.email)
        try validateEmail(normalizedEmail)
        // Not a change: nothing to re-verify and no session to end.
        guard normalizedEmail != normalizeEmail(user.email) else {
            throw Abort(.badRequest, reason: "EMAIL_UNCHANGED")
        }

        let currentPassword = payload.currentPassword ?? ""
        let passwordMatches = currentPassword.isEmpty
            ? false
            : try await req.password.async.verify(currentPassword, created: user.passwordHash).get()
        guard passwordMatches else {
            // OAuth-only accounts have a random password nobody knows; asking
            // for it again would never work. Support handles those for now.
            if user.passwordSetAt == nil {
                throw Abort(.conflict, reason: "REAUTH_REQUIRED")
            }
            if currentPassword.isEmpty {
                throw Abort(.badRequest, reason: "CURRENT_PASSWORD_REQUIRED")
            }
            // 400, not 401: clients treat a 401 as an expired session.
            throw Abort(.badRequest, reason: "INVALID_CURRENT_PASSWORD")
        }

        if let existing = try await repo.find(email: normalizedEmail, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Email already registered")
        }

        user.email = normalizedEmail
        user.emailVerifiedAt = nil
        let spared = Self.callerSession(refreshToken: payload.refreshToken, req: req)
        try await db.transaction { db in
            try await repo.save(user, on: db)
            try await req.application.authRepository.revokeAllTokens(userId: userId, sparing: spared, on: db)
        }
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func updatePassword(userId: UUID, payload: UpdatePasswordRequest, callerRefreshToken: String?, on req: Request) async throws {
        let db = req.db
        let user = try await requireUser(id: userId, on: db)

        // Verify current password. 400, not 401: clients treat a 401 as an
        // expired session and sign the user out over a typo.
        guard try await req.password.async.verify(payload.currentPassword, created: user.passwordHash).get() else {
            throw Abort(.badRequest, reason: "INVALID_CURRENT_PASSWORD")
        }

        // Hash and save new password
        user.passwordHash = try await req.password.async.hash(payload.newPassword).get()
        user.passwordSetAt = Date()
        // Sessions opened with the old password end; the caller's own session
        // survives. One transaction, so the password never changes alone.
        let spared = Self.callerSession(refreshToken: callerRefreshToken, req: req)
        try await db.transaction { db in
            try await repo.save(user, on: db)
            try await req.application.authRepository.revokeAllTokens(userId: userId, sparing: spared, on: db)
        }
    }

    /// The session making this request: its access token's `iat` and, when the
    /// client sent it, its refresh token.
    private static func callerSession(refreshToken: String?, req: Request) -> SparedSession {
        SparedSession(
            refreshTokenHash: refreshToken.map(OpaqueToken.sha256Hex),
            accessTokenIssuedAt: req.auth.get(SessionToken.self)?.iat?.value
        )
    }

    private func requireUser(id: UUID, on db: any Database) async throws -> User {
        guard let user = try await repo.find(id: id, on: db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return user
    }

    private func makeProfile(from user: User) -> UserProfile {
        UserProfile(
            id: user.id?.uuidString ?? "",
            email: user.email,
            bio: normalizeOptional(user.bio),
            avatarURL: user.avatarURLString.flatMap(URL.init(string:)),
            bannerAvatarURL: user.bannerAvatarURLString.flatMap(URL.init(string:)),
            username: normalizeOptional(user.username)
        )
    }

    private func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateEmail(_ email: String) throws {
        if email.isEmpty || !email.contains("@") {
            throw Abort(.badRequest, reason: "Invalid email")
        }
    }

    private func validateUsername(_ username: String?) throws {
        guard let username else { return }
        let pattern = #"^[a-zA-Z0-9_]{4,30}$"#
        if username.range(of: pattern, options: .regularExpression) == nil {
            throw Abort(.badRequest, reason: "Username must be 4-30 characters (letters, numbers, underscore)")
        }
        if DailyBoardIdentity.isSystemUsername(username) {
            throw Abort(.badRequest, reason: "That username is reserved.")
        }
    }
}
