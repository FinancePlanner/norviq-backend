import Fluent
import SQLKit

/// `email_verified_at`: when the account was proven to control its email. Null
/// for password sign-ups, which never verify. The OAuth sign-in path uses it to
/// tell a squatted account (someone registered the victim's email with a
/// password) from a real one before linking; see `DefaultAuthService.oauthExchange`.
///
/// `password_set_at`: when the user last chose a password. Null for accounts
/// whose hash is random (created by OAuth sign-in, or neutralised by the
/// takeover guard), so the email-change route can answer REAUTH_REQUIRED
/// instead of an unexplained 401.
///
/// `sessions_valid_after`: set by `AuthRepository.revokeAllTokens`. Access JWTs
/// issued before it (or with no `iat`) and refresh tokens created before it are
/// refused, so revocation reaches the stateless JWTs too. Null for everyone
/// until their first revocation, which keeps tokens minted before this release
/// working.
///
/// Columns only; existing rows are filled by `BackfillEmailVerifiedAtAndPasswordSetAt`,
/// which needs `oauth_identities` and so runs at the end of the list.
struct AddEmailVerifiedAtAndPasswordSetAtToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("email_verified_at", .datetime)
            .field("password_set_at", .datetime)
            .field("sessions_valid_after", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("email_verified_at")
            .deleteField("password_set_at")
            .deleteField("sessions_valid_after")
            .update()
    }
}

/// Fills `email_verified_at` and `password_set_at` for accounts that predate them:
///   * a user counts as verified only when one of their OAuth identities
///     carries the account's own email (case-insensitive) and the provider
///     marked it verified. An identity with another address (Apple relay,
///     a different Google account) proves nothing about this one;
///   * every user counts as having a password unless an OAuth identity was
///     created with the account (within a minute) — the OAuth sign-up path
///     inserts both back to back, while a later link is minutes or months apart.
///     A wrong guess here only changes the error code the email-change route
///     gives: a correct current password is accepted either way.
struct BackfillEmailVerifiedAtAndPasswordSetAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        UPDATE users u
        SET email_verified_at = oi.first_linked_at
        FROM (
            SELECT i.user_id, COALESCE(MIN(i.created_at), now()) AS first_linked_at
            FROM oauth_identities i
            JOIN users owner ON owner.id = i.user_id
            WHERE i.email_verified
              AND i.email IS NOT NULL
              AND lower(i.email) = lower(owner.email)
            GROUP BY i.user_id
        ) oi
        WHERE oi.user_id = u.id AND u.email_verified_at IS NULL
        """).run()
        try await sql.raw("""
        UPDATE users u
        SET password_set_at = COALESCE(u.created_at, now())
        WHERE u.password_set_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM oauth_identities oi
              WHERE oi.user_id = u.id
                AND oi.created_at <= u.created_at + interval '60 seconds'
          )
        """).run()
    }

    func revert(on _: any Database) async throws {
        // Data only; the columns go with AddEmailVerifiedAtAndPasswordSetAtToUsers.
    }
}
