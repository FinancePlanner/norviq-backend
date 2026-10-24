import Fluent
import Foundation
import Vapor

/// Who may see a user's achievements, shared by the profile showcase, the
/// friend achievements list and the activity feed.
struct AchievementVisibility: Sendable {
    /// The viewer may see the owner's achievements at all.
    let canSee: Bool
    /// Performance achievements are visible too (owner opted into return %,
    /// or the viewer is the owner).
    let canSeePerformance: Bool

    static let hidden = AchievementVisibility(canSee: false, canSeePerformance: false)

    /// Self always sees their own. Others: achievements on, friends, no block
    /// either way, owner not suspended, and the owner left sharing on.
    static func resolve(viewer: UUID, owner: UUID, on db: any Database) async throws -> AchievementVisibility {
        if viewer == owner {
            return AchievementVisibility(canSee: true, canSeePerformance: true)
        }
        guard AchievementsConfiguration.fromEnvironment().enabled,
              try await SocialService.areFriends(viewer, owner, on: db),
              try await !SocialService.isBlockedEitherWay(viewer, owner, on: db),
              try await !SocialService.isSuspended(owner, on: db)
        else { return .hidden }
        let settings = try await SocialService.settings(for: [owner], on: db)[owner] ?? .default
        guard settings.showAchievements else { return .hidden }
        return AchievementVisibility(canSee: true, canSeePerformance: settings.showReturnPercent)
    }

    /// The owner's unlock rows the viewer may see: no pre-engine `legacy.*`
    /// badges, no unknown keys, performance only when allowed. Newest first.
    static func visibleRows(of owner: UUID, access: AchievementVisibility, on db: any Database) async throws -> [UserAchievement] {
        guard access.canSee else { return [] }
        return try await UserAchievement.query(on: db)
            .filter(\.$user.$id == owner)
            .sort(\.$unlockedAt, .descending)
            .all()
            .filter { row in
                guard !row.achievementKey.hasPrefix("legacy."),
                      let definition = AchievementCatalogue.definition(row.achievementKey) else { return false }
                return access.canSeePerformance || !definition.isPerformance
            }
    }

    private static func tierWeight(_ tier: String) -> Int {
        switch tier {
        case "gold": 3
        case "silver": 2
        case "bronze": 1
        default: 0
        }
    }

    /// Pinned entries in rank order, else the three best by tier, then recency.
    /// `rows` must be newest first (see `visibleRows`).
    static func showcase(from rows: [UserAchievement], language: AchievementLanguage) -> [AchievementShowcaseEntryDTO] {
        let pinned = rows
            .filter { ($0.showcaseRank ?? 0) >= 1 && ($0.showcaseRank ?? 0) <= AchievementService.showcaseLimit }
            .sorted { ($0.showcaseRank ?? 0) < ($1.showcaseRank ?? 0) }
        let chosen: [UserAchievement] = if pinned.isEmpty {
            // Stable sort keeps newest first within a tier.
            Array(rows.enumerated()
                .sorted { a, b in
                    let (wa, wb) = (tierWeight(a.element.tier), tierWeight(b.element.tier))
                    return wa != wb ? wa > wb : a.offset < b.offset
                }
                .map(\.element)
                .prefix(AchievementService.showcaseLimit))
        } else {
            pinned
        }
        return chosen.compactMap { row in
            guard let definition = AchievementCatalogue.definition(row.achievementKey) else { return nil }
            let copy = definition.copy[language] ?? definition.copy[.en] ?? (definition.key, "")
            return AchievementShowcaseEntryDTO(key: row.achievementKey, tier: row.tier, title: copy.title, iconKey: definition.iconKey)
        }
    }

    /// Wire form of the owner's visible unlocks.
    static func unlocks(from rows: [UserAchievement], language: AchievementLanguage) -> [AchievementUnlockDTO] {
        rows.compactMap { row in
            guard let id = row.id, let definition = AchievementCatalogue.definition(row.achievementKey) else { return nil }
            let copy = definition.copy[language] ?? definition.copy[.en] ?? (definition.key, "")
            return AchievementUnlockDTO(
                id: id, key: row.achievementKey, tier: row.tier, title: copy.title, description: copy.description,
                iconKey: definition.iconKey, xp: definition.tiers.first { $0.tier == row.tier }?.xp ?? 0,
                unlockedAt: row.unlockedAt
            )
        }
    }
}
