import Crypto
import Foundation
import Vapor

/// Environment switches for the social layer. Everything is off unless
/// `SOCIAL_ENABLED` is set, so the routes can deploy before the app turns the
/// Friends tab on.
struct SocialConfiguration: Sendable {
    let enabled: Bool
    let contactsDiscovery: Bool
    let xImport: Bool
    /// XP, check-ins and friends leaderboards (Phase 3).
    let leaderboards: Bool
    let contactPepper: String?
    let inviteBaseURL: String

    static let contactHashVersion = 1

    static func fromEnvironment() -> SocialConfiguration {
        let enabled = envBool("SOCIAL_ENABLED", default: false)
        let pepper = Environment.get("SOCIAL_CONTACT_PEPPER")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePepper = (pepper?.isEmpty ?? true) ? nil : pepper
        let inviteBase = Environment.get("SOCIAL_INVITE_BASE_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SocialConfiguration(
            enabled: enabled,
            contactsDiscovery: enabled && usablePepper != nil && envBool("SOCIAL_CONTACTS_ENABLED", default: true),
            xImport: enabled && XOAuthProviderClient.Config.fromEnvironment() != nil
                && envBool("SOCIAL_X_IMPORT_ENABLED", default: false),
            leaderboards: enabled && envBool("SOCIAL_LEADERBOARDS_ENABLED", default: true),
            contactPepper: usablePepper,
            inviteBaseURL: (inviteBase?.isEmpty ?? true) ? "https://norviq.org" : inviteBase ?? "https://norviq.org"
        )
    }

    var dto: SocialConfigDTO {
        SocialConfigDTO(
            enabled: enabled,
            contactsDiscovery: contactsDiscovery,
            xImport: xImport,
            leaderboards: leaderboards,
            messaging: false,
            contactHashVersion: contactsDiscovery ? Self.contactHashVersion : nil,
            contactPepper: contactsDiscovery ? contactPepper : nil
        )
    }
}

/// Contact hashing, version 1. The app computes the same thing on device, so
/// raw addresses never leave the phone:
/// `hex(HMAC-SHA256(key: pepper, message: lowercase(trim(email))))`.
enum SocialContactHash {
    static func normalizedEmail(_ email: String) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), normalized.count >= 3 else { return nil }
        return normalized
    }

    static func hash(email: String, pepper: String) -> String? {
        guard let normalized = normalizedEmail(email) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(normalized.utf8),
            using: SymmetricKey(data: Data(pepper.utf8))
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
