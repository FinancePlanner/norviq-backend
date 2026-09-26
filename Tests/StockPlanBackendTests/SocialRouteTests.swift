import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Social contact hash")
struct SocialContactHashTests {
    /// The iOS app hashes on device with the same vector; keep them in sync.
    @Test("HMAC-SHA256 of the normalized email, lowercase hex")
    func knownVector() {
        let hash = SocialContactHash.hash(email: "  Ana@Example.com ", pepper: "test-pepper")
        #expect(hash == "daee873047f0f98be24af583ad20cf23023f1772bfa853aed2bb53967227737f")
        #expect(SocialContactHash.isWellFormed(hash ?? ""))
        #expect(SocialContactHash.hash(email: "not-an-email", pepper: "p") == nil)
    }
}

/// Friends graph against a real database: requests, invites, blocking,
/// visibility and contact matching.
@Suite("Social routes", .serialized)
struct SocialRouteTests {
    private func withApp(enabled: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", enabled ? "1" : "0", 1)
            setenv("SOCIAL_CONTACT_PEPPER", "test-pepper", 1)
            setenv("SOCIAL_INVITE_BASE_URL", "https://norviq.test", 1)
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

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "soc_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "soc+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func bearer(_ auth: AuthResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: auth.token)
        return headers
    }

    private func get<T: Decodable>(
        _ app: Application, _ path: String, as auth: AuthResponse, _: T.Type
    ) async throws -> T {
        var value: T?
        try await app.testing().test(.GET, path, headers: bearer(auth)) { res async throws in
            #expect(res.status == .ok, "GET \(path) -> \(res.status)")
            value = try res.content.decode(T.self)
        }
        return try #require(value)
    }

    private func status(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse,
        body: (any Content)? = nil
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.testing().test(method, path, headers: bearer(auth), beforeRequest: { req in
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            status = res.status
        })
        return status
    }

    private func friendIds(_ app: Application, of auth: AuthResponse) async throws -> [UUID] {
        try await get(app, "v1/social/friends", as: auth, SocialFriendsListResponse.self).friends.map(\.id)
    }

    @Test("Disabled: config says so and the other routes 404")
    func disabled() async throws {
        try await withApp(enabled: false) { app in
            let a = try await register(app, "off1")
            let config = try await get(app, "v1/social/config", as: a, SocialConfigDTO.self)
            #expect(config.enabled == false)
            #expect(config.contactPepper == nil)
            #expect(try await status(app, .GET, "v1/social/friends", as: a) == .notFound)
        }
    }

    @Test("Request, accept, then both see the friendship")
    func requestAndAccept() async throws {
        try await withApp { app in
            let a = try await register(app, "req1")
            let b = try await register(app, "req2")

            #expect(try await status(app, .POST, "v1/social/friend-requests", as: a,
                                     body: SocialSendFriendRequestBody(userId: b.userId)) == .ok)
            // Sending again is a no-op, not a second request.
            #expect(try await status(app, .POST, "v1/social/friend-requests", as: a,
                                     body: SocialSendFriendRequestBody(userId: b.userId)) == .ok)

            let incoming = try await get(app, "v1/social/friend-requests", as: b, SocialFriendRequestsResponse.self).incoming
            #expect(incoming.count == 1)
            #expect(incoming.first?.from.friendshipStatus == .incomingPending)
            let requestId = try #require(incoming.first?.id)

            #expect(try await status(app, .POST, "v1/social/friend-requests/\(requestId)/accept", as: b) == .noContent)
            #expect(try await friendIds(app, of: a) == [b.userId])
            #expect(try await friendIds(app, of: b) == [a.userId])
            #expect(try await get(app, "v1/social/friend-requests", as: b, SocialFriendRequestsResponse.self).incoming.isEmpty)
        }
    }

    @Test("Adding someone who already asked accepts their request")
    func reverseRequestAccepts() async throws {
        try await withApp { app in
            let a = try await register(app, "rev1")
            let b = try await register(app, "rev2")
            _ = try await status(app, .POST, "v1/social/friend-requests", as: a,
                                 body: SocialSendFriendRequestBody(userId: b.userId))
            #expect(try await status(app, .POST, "v1/social/friend-requests", as: b,
                                     body: SocialSendFriendRequestBody(userId: a.userId)) == .ok)
            #expect(try await friendIds(app, of: b) == [a.userId])
            #expect(try await status(app, .POST, "v1/social/friend-requests", as: b,
                                     body: SocialSendFriendRequestBody(userId: a.userId)) == .conflict)
        }
    }

    @Test("Blocking ends the friendship and hides both people from each other")
    func blockHidesBothWays() async throws {
        try await withApp { app in
            let a = try await register(app, "blk1")
            let b = try await register(app, "blk2")
            let invite = try await get(app, "v1/social/friends", as: a, SocialFriendsListResponse.self)
            #expect(invite.friends.isEmpty)
            var link: SocialInviteLinkDTO?
            try await app.testing().test(.POST, "v1/social/invites", headers: bearer(a)) { res async throws in
                link = try res.content.decode(SocialInviteLinkDTO.self)
            }
            let code = try #require(link?.code)
            #expect(link?.url == "https://norviq.test/i/\(code)")
            #expect(try await status(app, .POST, "v1/social/invites/\(code)/redeem", as: b) == .ok)
            #expect(try await friendIds(app, of: a) == [b.userId])

            #expect(try await status(app, .POST, "v1/social/blocks/\(b.userId)", as: a) == .noContent)
            #expect(try await friendIds(app, of: a).isEmpty)
            #expect(try await friendIds(app, of: b).isEmpty)
            #expect(try await status(app, .GET, "v1/social/users/\(a.userId)", as: b) == .notFound)
            #expect(try await status(app, .GET, "v1/social/invites/\(code)", as: b) == .notFound)
            let search = try await get(app, "v1/social/users/search?q=soc_blk", as: b, SocialUserSearchResponse.self)
            #expect(search.users.contains { $0.id == a.userId } == false)
            let blocked = try await get(app, "v1/social/blocks", as: a, SocialBlockedUsersResponse.self)
            #expect(blocked.users.map(\.id) == [b.userId])
        }
    }

    @Test("Own invite can't be redeemed")
    func ownInvite() async throws {
        try await withApp { app in
            let a = try await register(app, "own1")
            var link: SocialInviteLinkDTO?
            try await app.testing().test(.POST, "v1/social/invites", headers: bearer(a)) { res async throws in
                link = try res.content.decode(SocialInviteLinkDTO.self)
            }
            let code = try #require(link?.code)
            #expect(try await status(app, .POST, "v1/social/invites/\(code)/redeem", as: a) == .badRequest)
        }
    }

    @Test("Search respects 'nobody' and never returns the caller")
    func searchVisibility() async throws {
        try await withApp { app in
            let a = try await register(app, "vis1")
            let b = try await register(app, "vis2")
            var found = try await get(app, "v1/social/users/search?q=soc_vis", as: a, SocialUserSearchResponse.self)
            #expect(found.users.map(\.id) == [b.userId])

            var hidden = SocialPrivacySettingsDTO.default
            hidden.searchVisibility = .nobody
            #expect(try await status(app, .PUT, "v1/social/privacy", as: b, body: hidden) == .ok)
            found = try await get(app, "v1/social/users/search?q=soc_vis", as: a, SocialUserSearchResponse.self)
            #expect(found.users.isEmpty)
        }
    }

    @Test("Privacy defaults keep return % private")
    func privacyDefaults() async throws {
        try await withApp { app in
            let a = try await register(app, "prv1")
            let settings = try await get(app, "v1/social/privacy", as: a, SocialPrivacySettingsDTO.self)
            #expect(settings.showReturnPercent == false)
            #expect(settings.searchVisibility == .everyone)
        }
    }

    @Test("Contact matching finds opted-in users by email hash only")
    func contactMatching() async throws {
        try await withApp { app in
            let a = try await register(app, "con1")
            let b = try await register(app, "con2")
            let config = try await get(app, "v1/social/config", as: b, SocialConfigDTO.self)
            #expect(config.contactsDiscovery)
            #expect(config.contactHashVersion == 1)
            let pepper = try #require(config.contactPepper)
            let hash = try #require(SocialContactHash.hash(email: "SOC+con2@example.com", pepper: pepper))
            let body = SocialContactMatchBody(hashVersion: 1, items: [
                SocialContactHashItem(hash: hash, kind: .email),
                SocialContactHashItem(hash: String(repeating: "a", count: 64), kind: .email),
            ])

            var matches: [SocialContactMatch] = []
            try await app.testing().test(.POST, "v1/social/discovery/contacts/match", headers: bearer(a), beforeRequest: { req in
                try req.content.encode(body)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                matches = try res.content.decode(SocialContactMatchResponse.self).matches
            })
            #expect(matches.map(\.user.id) == [b.userId])
            #expect(matches.first?.hash == hash)

            var optedOut = SocialPrivacySettingsDTO.default
            optedOut.discoverableByContacts = false
            _ = try await status(app, .PUT, "v1/social/privacy", as: b, body: optedOut)
            try await app.testing().test(.POST, "v1/social/discovery/contacts/match", headers: bearer(a), beforeRequest: { req in
                try req.content.encode(body)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(SocialContactMatchResponse.self).matches.isEmpty)
            })
        }
    }

    @Test("Reports are accepted for review")
    func report() async throws {
        try await withApp { app in
            let a = try await register(app, "rep1")
            let b = try await register(app, "rep2")
            let body = SocialReportBody(targetType: .user, targetId: b.userId.uuidString, reason: .spam, note: "  ")
            #expect(try await status(app, .POST, "v1/social/reports", as: a, body: body) == .accepted)
            let stored = try await SocialReport.query(on: app.db).all()
            #expect(stored.count == 1)
            #expect(stored.first?.note == nil)
        }
    }
}
