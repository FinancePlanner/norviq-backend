import Foundation
import Vapor

/// Digest switches, read once at boot and stored so tests can flip them.
struct DigestConfig: Sendable {
    /// `DIGEST_ENABLED`: the scheduled job and the signed-in routes.
    var enabled = false
    /// `DIGEST_EMAIL_ENABLED`: the email channel.
    var emailEnabled = false
    /// `DIGEST_MAX_EMAILS_PER_TICK`: digests claimed per 15-minute tick. Paces
    /// sends on the Resend domain that also carries MFA codes.
    var maxPerTick = 25
    /// `DIGEST_USER_ALLOWLIST`: comma-separated user ids. Empty means everyone.
    var allowlist: Set<UUID> = []
    /// `DIGEST_WEB_BASE_URL`: where email links land.
    var webBaseURL = "https://norviq.org"
    /// `PUBLIC_API_BASE_URL`: the one-click unsubscribe endpoint.
    var apiBaseURL = "https://api.norviq.org"

    func allows(_ userId: UUID) -> Bool {
        allowlist.isEmpty || allowlist.contains(userId)
    }

    static func fromEnvironment() -> DigestConfig {
        var config = DigestConfig()
        config.enabled = envBool("DIGEST_ENABLED", default: false)
        config.emailEnabled = envBool("DIGEST_EMAIL_ENABLED", default: false)
        config.maxPerTick = max(Environment.get("DIGEST_MAX_EMAILS_PER_TICK").flatMap(Int.init) ?? 25, 1)
        config.allowlist = Set(
            (Environment.get("DIGEST_USER_ALLOWLIST") ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        )
        if let web = Environment.get("DIGEST_WEB_BASE_URL"), !web.isEmpty {
            config.webBaseURL = web.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let api = Environment.get("PUBLIC_API_BASE_URL"), !api.isEmpty {
            config.apiBaseURL = api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return config
    }
}

extension Application {
    private struct DigestConfigKey: StorageKey {
        typealias Value = DigestConfig
    }

    private struct DigestDataSourcesKey: StorageKey {
        typealias Value = any DigestDataSources
    }

    var digestConfig: DigestConfig {
        get { storage[DigestConfigKey.self] ?? DigestConfig() }
        set { storage[DigestConfigKey.self] = newValue }
    }

    var digestDataSources: any DigestDataSources {
        get { storage[DigestDataSourcesKey.self] ?? LiveDigestDataSources() }
        set { storage[DigestDataSourcesKey.self] = newValue }
    }
}
