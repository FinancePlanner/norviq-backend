import Atomics
import Fluent
import FluentSQL
import Foundation
import Vapor

/// "Find friends from Facebook". iOS sends a Limited Login id token whose
/// `user_friends` claim lists friend ids; the web runs classic Facebook Login
/// and the friend list comes from the Graph API. Either way the caller's
/// Facebook id is linked as an `oauth_identities` row (provider "facebook",
/// never usable to sign in: `OAuthProvider` has no such case) and the granted
/// friend ids are kept in `social_facebook_friends` until unlinked.
///
/// Facebook only returns friends who also use Norviq with Facebook and
/// granted `user_friends`, so every id is a potential match. Access tokens
/// are used for the one request and never stored.
enum FacebookFriendsImport {
    static let provider = "facebook"
    static let flowPurpose = "social_facebook_import"
    static let graphBaseURL = "https://graph.facebook.com/v21.0"
    static let scopes = "public_profile,user_friends"
    /// 500 a page; ten pages is far beyond what Facebook returns in practice.
    static let maxPages = 10
    static let alreadyLinkedReason = "This Facebook account is already connected to another Norviq account."

    private static let missingSecretLogged = ManagedAtomic<Bool>(false)

    // MARK: - Routes

    /// iOS Limited Login.
    @Sendable
    static func limited(req: Request) async throws -> SocialFacebookMatchesResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let config = try requireConfig()
        let body = try req.content.decode(SocialFacebookLimitedLoginBody.self)
        let idToken = body.idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonce = body.nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idToken.isEmpty, !nonce.isEmpty else {
            throw Abort(.badRequest, reason: "idToken and nonce are required")
        }

        let kid = try oauthParseJWTHeader(idToken)["kid"] as? String
        let jwks = try await req.application.facebookJWKSProvider.jwks(containing: kid, on: req)
        let claims = try await FacebookLimitedLogin.verify(idToken, nonce: nonce, appIDs: config.appIDs, jwks: jwks)
        return try await linkAndMatch(
            userId: userId,
            facebookId: claims.sub,
            friendIds: claims.userFriends?.ids ?? [],
            on: req.db
        )
    }

    /// Web: classic Facebook Login, step one.
    @Sendable
    static func start(req: Request) async throws -> OAuthStartResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let (config, _) = try requireWebConfig(logger: req.logger)
        let body = try req.content.decode(OAuthStartRequest.self)
        let redirectURI = try XFollowingImport.validatedRedirectURI(body.redirectURI, app: req.application)

        let state = XFollowingImport.randomURLSafeString(length: 32)
        let expiresIn = 600
        // Facebook's dialog takes no PKCE or nonce here; the columns are
        // required, so they hold unused random values.
        let flow = OAuthFlow(
            provider: provider,
            state: state,
            nonce: XFollowingImport.randomURLSafeString(length: 32),
            codeVerifier: XFollowingImport.randomURLSafeString(length: 64),
            redirectURI: redirectURI,
            purpose: flowPurpose,
            userId: userId,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        try await flow.save(on: req.db)
        guard let flowId = flow.id else {
            throw Abort(.internalServerError, reason: "OAuth flow id missing")
        }

        var components = URLComponents(string: "https://www.facebook.com/v21.0/dialog/oauth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.webAppID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        guard let url = components?.url else {
            throw Abort(.internalServerError, reason: "Failed to build Facebook authorization URL")
        }
        return OAuthStartResponse(flowId: flowId, authorizationURL: url.absoluteString, expiresIn: expiresIn)
    }

    /// Web: classic Facebook Login, step two.
    @Sendable
    static func exchange(req: Request) async throws -> SocialFacebookMatchesResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let (config, appSecret) = try requireWebConfig(logger: req.logger)
        let body = try req.content.decode(OAuthExchangeRequest.self)
        let redirectURI = try XFollowingImport.normalizedRedirectURI(body.redirectURI)

        guard let flow = try await OAuthFlow.find(body.flowId, on: req.db),
              flow.provider == provider,
              flow.purpose == flowPurpose,
              flow.userId == userId,
              flow.usedAt == nil,
              flow.expiresAt > Date()
        else {
            throw Abort(.unauthorized, reason: "Facebook import flow is invalid or expired")
        }
        guard flow.state == body.state.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Abort(.unauthorized, reason: "OAuth state mismatch")
        }
        guard flow.redirectURI == redirectURI else {
            throw Abort(.unauthorized, reason: "OAuth redirect URI mismatch")
        }
        flow.usedAt = Date()
        try await flow.save(on: req.db)

        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw Abort(.badRequest, reason: "OAuth authorization code is required")
        }
        let graph = FacebookGraph(
            client: req.application.facebookGraphClient,
            appID: config.webAppID,
            appSecret: appSecret,
            req: req
        )
        let accessToken = try await graph.exchangeCode(code, redirectURI: redirectURI)
        let facebookId = try await graph.meID(token: accessToken)
        let friendIds = try await graph.friendIDs(token: accessToken)
        return try await linkAndMatch(userId: userId, facebookId: facebookId, friendIds: friendIds, on: req.db)
    }

    /// Unlink and forget the friend list (also Facebook's data deletion path).
    @Sendable
    static func disconnect(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        _ = try requireConfig()
        try await req.db.transaction { db in
            try await OAuthIdentity.query(on: db)
                .filter(\.$user.$id == userId)
                .filter(\.$provider == provider)
                .delete()
            try await sqlDatabase(db).delete(from: "social_facebook_friends")
                .where("user_id", .equal, SQLBind(userId))
                .run()
        }
        return .noContent
    }

    // MARK: - Link + match

    /// Links `facebookId` to the caller (one Facebook account per user and
    /// per Facebook account), replaces their stored friend ids, and returns
    /// the friends already on Norviq that they're allowed to see.
    static func linkAndMatch(
        userId: UUID,
        facebookId rawFacebookId: String,
        friendIds rawFriendIds: [String],
        on db: any Database
    ) async throws -> SocialFacebookMatchesResponse {
        let facebookId = rawFacebookId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !facebookId.isEmpty else {
            throw Abort(.badGateway, reason: "Facebook didn't return an account id.")
        }
        var seen = Set<String>()
        let friendIds = rawFriendIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != facebookId && seen.insert($0).inserted }

        do {
            try await link(userId: userId, facebookId: facebookId, friendIds: friendIds, on: db)
        } catch where XPService.isConstraintFailure(error) {
            // Lost a race with another account claiming the same Facebook id.
            throw Abort(.conflict, reason: alreadyLinkedReason)
        }
        let matches = try await matches(for: userId, friendIds: friendIds, on: db)
        return SocialFacebookMatchesResponse(matches: matches, friendsGranted: friendIds.count)
    }

    private static func link(userId: UUID, facebookId: String, friendIds: [String], on db: any Database) async throws {
        try await db.transaction { db in
            let existing = try await OAuthIdentity.query(on: db)
                .filter(\.$provider == provider)
                .filter(\.$providerUserID == facebookId)
                .first()
            if let existing, existing.$user.id != userId {
                throw Abort(.conflict, reason: alreadyLinkedReason)
            }
            try await OAuthIdentity.query(on: db)
                .filter(\.$user.$id == userId)
                .filter(\.$provider == provider)
                .filter(\.$providerUserID != facebookId)
                .delete()
            if existing == nil {
                try await OAuthIdentity(
                    userID: userId,
                    provider: provider,
                    providerUserID: facebookId,
                    email: nil,
                    emailVerified: false
                ).create(on: db)
            }

            let sql = try sqlDatabase(db)
            try await sql.delete(from: "social_facebook_friends")
                .where("user_id", .equal, SQLBind(userId))
                .run()
            var start = friendIds.startIndex
            while start < friendIds.endIndex {
                let end = min(start + 1000, friendIds.endIndex)
                let insert = sql.insert(into: "social_facebook_friends").columns("user_id", "facebook_id")
                for id in friendIds[start ..< end] {
                    insert.values([SQLBind(userId), SQLBind(id)])
                }
                try await insert.run()
                start = end
            }
        }
    }

    private static func matches(
        for userId: UUID,
        friendIds: [String],
        on db: any Database
    ) async throws -> [SocialFacebookMatch] {
        guard !friendIds.isEmpty else { return [] }
        let identities = try await OAuthIdentity.query(on: db)
            .filter(\.$provider == provider)
            .filter(\.$providerUserID ~~ friendIds)
            .all()
        let hidden = try await SocialService.blockedEitherWay(for: userId, on: db)
        let candidates = Set(identities.map(\.$user.id)).subtracting(hidden).subtracting([userId])
        let settings = try await SocialService.settings(for: Array(candidates), on: db)
        let allowed = candidates.filter { settings[$0]?.discoverableByFacebook ?? true }
        let summaries = try await SocialService.summaries(for: Array(allowed), viewer: userId, on: db)
        return summaries.values
            .sorted { $0.username.lowercased() < $1.username.lowercased() }
            .map { SocialFacebookMatch(user: $0) }
    }

    // MARK: - Config

    private static func requireConfig() throws -> FacebookImportConfig {
        guard SocialConfiguration.fromEnvironment().facebookImport else {
            throw Abort(.notFound, reason: "Facebook import is not available.")
        }
        return FacebookImportConfig.fromEnvironment()
    }

    /// The web flow also needs the app secret; iOS doesn't.
    private static func requireWebConfig(logger: Logger) throws -> (FacebookImportConfig, String) {
        let config = try requireConfig()
        guard let secret = config.appSecret else {
            if missingSecretLogged.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                logger.warning("social.facebook_import web flow unavailable: FACEBOOK_APP_SECRET is not set")
            }
            throw Abort(.notFound, reason: "Facebook import is not available.")
        }
        return (config, secret)
    }

    private static func sqlDatabase(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }
        return sql
    }
}

/// `FACEBOOK_APP_ID` may list several ids (comma-separated) so one backend
/// can accept tokens from more than one Meta app; the first is used for the
/// web dialog.
struct FacebookImportConfig: Sendable {
    let appIDs: [String]
    let appSecret: String?

    var webAppID: String {
        appIDs.first ?? ""
    }

    static func fromEnvironment() -> FacebookImportConfig {
        let ids = (Environment.get("FACEBOOK_APP_ID") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let secret = Environment.get("FACEBOOK_APP_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FacebookImportConfig(appIDs: ids, appSecret: (secret?.isEmpty ?? true) ? nil : secret)
    }
}
