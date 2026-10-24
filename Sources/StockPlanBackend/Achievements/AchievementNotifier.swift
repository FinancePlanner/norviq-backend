import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Tells a user about their own new unlocks: one push per evaluation, to the
/// devices whose app understands achievement pushes.
///
/// Only the hook and sweep paths call it. The `GET /v1/achievements` listing
/// evaluates too but never pushes: the app shows its own sheet there.
enum AchievementNotifier {
    /// Device capability of an app that can open achievement pushes.
    static let capability = "achievements_v1"
    /// `social_activity.kind` of an unlock.
    static let activityKind = "achievement_unlocked"

    /// Pushes the live and sweep unlocks among `unlocks` (backfill and legacy
    /// ones are never news) and stamps their `notified_at`. Does nothing
    /// without a capable device. Never throws; failures are logged.
    static func notifyUnlocks(_ unlocks: [UserAchievement], userId: UUID, app: Application) async {
        let news = unlocks.filter { $0.source == AchievementSource.live.rawValue || $0.source == AchievementSource.sweep.rawValue }
        guard let message = message(for: news) else { return }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db).filter(isCapable)
            guard !devices.isEmpty else { return }
            _ = await app.pushNotificationSender.sendSocialEvent(message: message, devices: devices, req: req)
            let ids = news.compactMap(\.id)
            try await UserAchievement.query(on: req.db)
                .filter(\.$id ~~ ids)
                .set(\.$notifiedAt, to: Date())
                .update()
        } catch {
            req.logger.warning("achievements.push failed error=\(String(reflecting: type(of: error)))")
        }
    }

    /// English copy (the user's language is not tracked server-side): the
    /// achievement's title for one unlock — its real title even when hidden,
    /// with the tier for a tiered one — or a count for several.
    static func message(for unlocks: [UserAchievement]) -> SocialPushMessage? {
        guard let first = unlocks.first else { return nil }
        if unlocks.count > 1 {
            return SocialPushMessage(
                kind: .achievementUnlocked, title: "Achievements unlocked", body: "\(unlocks.count) achievements unlocked"
            )
        }
        return SocialPushMessage(kind: .achievementUnlocked, title: "Achievement unlocked", body: title(of: first))
    }

    private static func title(of unlock: UserAchievement) -> String {
        let definition = AchievementCatalogue.definition(unlock.achievementKey) ?? legacyDefinition(unlock.achievementKey)
        let base = definition?.copy[.en]?.title ?? "New achievement"
        guard !unlock.tier.isEmpty else { return base }
        return "\(base) (\(unlock.tier.capitalized))"
    }

    private static func legacyDefinition(_ key: String) -> AchievementDefinition? {
        guard key.hasPrefix("legacy."), let badge = BadgeType(rawValue: String(key.dropFirst("legacy.".count))) else {
            return nil
        }
        return AchievementCatalogue.legacyDefinition(for: badge)
    }

    private static func isCapable(_ device: PushDevice) -> Bool {
        let values = (try? JSONDecoder().decode([String].self, from: Data(device.capabilitiesJSON.utf8))) ?? []
        return values.contains(capability)
    }
}
