import Foundation
import Vapor

// Wire types for /v1/social. They mirror financeplan/API/Social/SocialDTOs.swift
// in the iOS app field for field; both move to norviq-shared once the shape
// settles. Contract: norviq-ios financeplan/Documentation/social_api.md.

enum SocialFriendshipStatus: String, Codable, Sendable {
    case none
    case outgoingPending = "outgoing_pending"
    case incomingPending = "incoming_pending"
    case friends
    case blocked
}

enum SocialSearchVisibility: String, Codable, Sendable, CaseIterable {
    case everyone
    case friendsOfFriends = "friends_of_friends"
    case nobody
}

struct SocialUserSummaryDTO: Content, Equatable {
    let id: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let friendshipStatus: SocialFriendshipStatus
    let mutualFriendCount: Int?
}

struct SocialProfileDTO: Content, Equatable {
    let user: SocialUserSummaryDTO
    let streakDays: Int?
    let xpLevel: Int?
    let badgeCount: Int?
    let joinedAt: Date?
}

struct SocialFriendRequestDTO: Content, Equatable {
    let id: UUID
    let from: SocialUserSummaryDTO
    let to: SocialUserSummaryDTO
    let createdAt: Date
}

struct SocialFriendsListResponse: Content, Equatable {
    let friends: [SocialUserSummaryDTO]
    let nextCursor: String?
}

struct SocialFriendRequestsResponse: Content, Equatable {
    let incoming: [SocialFriendRequestDTO]
    let outgoing: [SocialFriendRequestDTO]
}

struct SocialUserSearchResponse: Content, Equatable {
    let users: [SocialUserSummaryDTO]
    let nextCursor: String?
}

struct SocialSendFriendRequestBody: Content {
    let userId: UUID
}

struct SocialInviteLinkDTO: Content, Equatable {
    let code: String
    let url: String
    let expiresAt: Date?
}

struct SocialInviteRedeemResponse: Content, Equatable {
    let inviter: SocialUserSummaryDTO
}

struct SocialPrivacySettingsDTO: Content, Equatable {
    var searchVisibility: SocialSearchVisibility
    var discoverableByContacts: Bool
    var discoverableByX: Bool
    var discoverableByFacebook: Bool
    var showReturnPercent: Bool
    var showStreaks: Bool
    var showXP: Bool
    var leaderboardOptIn: Bool

    /// Return % stays private until the user opts in.
    static let `default` = SocialPrivacySettingsDTO(
        searchVisibility: .everyone,
        discoverableByContacts: true,
        discoverableByX: true,
        discoverableByFacebook: true,
        showReturnPercent: false,
        showStreaks: true,
        showXP: true,
        leaderboardOptIn: true
    )
}

extension SocialPrivacySettingsDTO {
    /// Apps released before Facebook import don't send
    /// `discoverableByFacebook`; `PUT /privacy` keeps the stored value then
    /// (see `SocialController.updatePrivacy`).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            searchVisibility: container.decode(SocialSearchVisibility.self, forKey: .searchVisibility),
            discoverableByContacts: container.decode(Bool.self, forKey: .discoverableByContacts),
            discoverableByX: container.decode(Bool.self, forKey: .discoverableByX),
            discoverableByFacebook: container.decodeIfPresent(Bool.self, forKey: .discoverableByFacebook) ?? true,
            showReturnPercent: container.decode(Bool.self, forKey: .showReturnPercent),
            showStreaks: container.decode(Bool.self, forKey: .showStreaks),
            showXP: container.decode(Bool.self, forKey: .showXP),
            leaderboardOptIn: container.decode(Bool.self, forKey: .leaderboardOptIn)
        )
    }
}

/// Only used to tell whether a `PUT /privacy` body carried the field at all.
struct SocialFacebookPrivacyProbe: Decodable {
    let discoverableByFacebook: Bool?
}

struct SocialBlockedUsersResponse: Content, Equatable {
    let users: [SocialUserSummaryDTO]
}

enum SocialReportReason: String, Codable, Sendable, CaseIterable {
    case spam
    case harassment
    case hate
    case scam
    case impersonation
    case inappropriate
    case other
}

enum SocialReportTargetType: String, Codable, Sendable {
    case user
    case message
}

struct SocialReportBody: Content {
    let targetType: SocialReportTargetType
    let targetId: String
    let reason: SocialReportReason
    let note: String?
}

struct SocialConfigDTO: Content, Equatable {
    let enabled: Bool
    let contactsDiscovery: Bool
    let xImport: Bool
    let facebookImport: Bool
    let leaderboards: Bool
    let messaging: Bool
    /// Present when contact matching is on. The pepper is not a secret: it
    /// only stops precomputed tables; rate limits and opt-in do the rest.
    let contactHashVersion: Int?
    let contactPepper: String?
}

enum SocialContactKind: String, Codable, Sendable {
    case email
    case phone
}

struct SocialContactHashItem: Content {
    let hash: String
    let kind: SocialContactKind
}

struct SocialContactMatchBody: Content {
    let hashVersion: Int
    let items: [SocialContactHashItem]
}

struct SocialContactMatch: Content, Equatable {
    let hash: String
    let user: SocialUserSummaryDTO
}

struct SocialContactMatchResponse: Content, Equatable {
    let matches: [SocialContactMatch]
}

struct SocialXImportMatch: Content, Equatable {
    let xHandle: String
    let user: SocialUserSummaryDTO
}

struct SocialXImportMatchesResponse: Content, Equatable {
    let matches: [SocialXImportMatch]
    let totalFollowingScanned: Int
}

struct SocialFacebookLimitedLoginBody: Content {
    let idToken: String
    let nonce: String
}

struct SocialFacebookMatch: Content, Equatable {
    let user: SocialUserSummaryDTO
}

struct SocialFacebookMatchesResponse: Content, Equatable {
    let matches: [SocialFacebookMatch]
    /// How many friend ids Facebook shared, matched or not.
    let friendsGranted: Int
}
