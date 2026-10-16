import Fluent
import Foundation
import StockPlanShared
import Vapor

/// `RECAP_ENABLED` gates everything; `RECAP_YEARLY_ENABLED` additionally gates
/// year recaps. Only the literal `"true"` turns a flag on.
struct RecapConfig: Sendable {
    let enabled: Bool
    let yearlyEnabled: Bool

    static func fromEnvironment() -> RecapConfig {
        RecapConfig(
            enabled: Environment.get("RECAP_ENABLED") == "true",
            yearlyEnabled: Environment.get("RECAP_YEARLY_ENABLED") == "true"
        )
    }
}

/// Serves a user's recaps. A deck is generated the first time its period is
/// asked for and frozen from then on; nil means "not available" (→ 404).
struct RecapService: Sendable {
    let repository: any RecapRepository
    let collector: RecapFactsCollector
    let config: RecapConfig

    init(repository: any RecapRepository, collector: RecapFactsCollector = .init(), config: RecapConfig) {
        self.repository = repository
        self.collector = collector
        self.config = config
    }

    func recap(userId: UUID, period: RecapPeriod, now: Date, on db: any Database) async throws -> RecapResponse? {
        guard serves(period.kind) else { return nil }

        // Generate once: a stored deck is served forever, however old.
        // Availability only gates generation.
        if let existing = try await repository.find(userId: userId, kind: period.kind, key: period.key, on: db) {
            return try existing.response()
        }

        guard let user = try await User.find(userId, on: db) else { return nil }
        let timeZone = try await RecapTimeZoneResolver.timeZone(for: userId, on: db)
        guard Self.isAvailable(period, now: now, timeZone: timeZone, user: user) else { return nil }

        let facts = try await collector.collect(userId: userId, period: period, timeZone: timeZone, on: db)
        let deck = RecapDeckBuilder.build(facts: facts, period: period)
        let stored = try await repository.insertOrFetch(
            RecapRecord(userId: userId, deck: deck, generatedAt: now), on: db
        )
        return try stored.response()
    }

    /// Every stored recap of a served kind, plus an un-generated entry for
    /// the last closed month (and, during January with yearly on, the last
    /// closed year) if none is stored.
    /// Never generates.
    func list(userId: UUID, now: Date, on db: any Database) async throws -> RecapListResponse {
        guard config.enabled, let user = try await User.find(userId, on: db) else {
            return RecapListResponse(recaps: [])
        }
        let timeZone = try await RecapTimeZoneResolver.timeZone(for: userId, on: db)

        var stored: [RecapSummary] = []
        var storedKeys: Set<String> = []
        for record in try await repository.list(userId: userId, on: db) {
            guard let kind = RecapPeriodKind(rawValue: record.periodKind),
                  let period = RecapPeriod.parse(kind: kind.rawValue, key: record.periodKey),
                  serves(kind)
            else { continue }
            storedKeys.insert("\(kind.rawValue)/\(record.periodKey)")
            stored.append(RecapSummary(
                kind: kind, key: record.periodKey, periodLabel: period.label, id: record.id,
                generated: true, openedAt: record.openedAt, completedAt: record.completedAt
            ))
        }

        var candidates = [RecapPeriod.lastClosedMonth(now: now, in: timeZone)]
        // The un-generated year entry is offered only in January (user's zone);
        // a stored year row is listed above all year long.
        if config.yearlyEnabled, Self.isJanuary(now, in: timeZone) {
            candidates.append(RecapPeriod.lastClosedYear(now: now, in: timeZone))
        }
        let pending = candidates
            .filter { !storedKeys.contains("\($0.kind.rawValue)/\($0.key)") }
            .filter { Self.isAvailable($0, now: now, timeZone: timeZone, user: user) }
            .map {
                RecapSummary(
                    kind: $0.kind, key: $0.key, periodLabel: $0.label, id: nil,
                    generated: false, openedAt: nil, completedAt: nil
                )
            }

        return RecapListResponse(recaps: pending + stored)
    }

    /// Sets `opened_at` the first time only. False when the recap is not this user's.
    func markOpened(id: UUID, userId: UUID, now: Date, on db: any Database) async throws -> Bool {
        try await stamp(id: id, userId: userId, on: db) { record in
            guard record.openedAt == nil else { return false }
            record.openedAt = now
            return true
        }
    }

    /// Sets `completed_at` the first time only. False when the recap is not this user's.
    func markCompleted(id: UUID, userId: UUID, now: Date, on db: any Database) async throws -> Bool {
        try await stamp(id: id, userId: userId, on: db) { record in
            guard record.completedAt == nil else { return false }
            record.completedAt = now
            return true
        }
    }

    private func stamp(
        id: UUID, userId: UUID, on db: any Database, _ apply: (RecapRecord) -> Bool
    ) async throws -> Bool {
        guard let record = try await repository.find(id: id, userId: userId, on: db) else { return false }
        if apply(record) {
            try await record.save(on: db)
        }
        return true
    }

    private func serves(_ kind: RecapPeriodKind) -> Bool {
        switch kind {
        case .month: config.enabled
        case .year: config.enabled && config.yearlyEnabled
        }
    }

    private static func isJanuary(_ now: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.month, from: now) == 1
    }

    /// A nil `createdAt` means no signup bound.
    private static func isAvailable(_ period: RecapPeriod, now: Date, timeZone: TimeZone, user: User) -> Bool {
        period.isAvailable(now: now, timeZone: timeZone, userCreatedAt: user.createdAt ?? .distantPast)
    }
}
