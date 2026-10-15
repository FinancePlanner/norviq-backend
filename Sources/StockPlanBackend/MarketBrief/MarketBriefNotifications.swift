import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol MarketBriefNotificationPreferenceServicing: Sendable {
    func get(userId: UUID, on db: any Database) async throws -> MarketBriefNotificationPreferences
    func update(
        userId: UUID,
        payload: MarketBriefNotificationPreferences,
        on db: any Database
    ) async throws -> MarketBriefNotificationPreferences
}

struct DatabaseMarketBriefNotificationPreferenceService: MarketBriefNotificationPreferenceServicing {
    func get(userId: UUID, on db: any Database) async throws -> MarketBriefNotificationPreferences {
        let preference = try await MarketBriefNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        return .init(
            enabled: preference?.enabled ?? false,
            language: preference?.language ?? MarketBriefLanguage.en.rawValue
        )
    }

    func update(
        userId: UUID,
        payload: MarketBriefNotificationPreferences,
        on db: any Database
    ) async throws -> MarketBriefNotificationPreferences {
        let language = MarketBriefLanguage.resolve(payload.language).rawValue
        let preference = try await MarketBriefNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
            ?? MarketBriefNotificationPreference(userId: userId, enabled: payload.enabled, language: language)
        preference.enabled = payload.enabled
        preference.language = language
        try await preference.save(on: db)
        return .init(enabled: preference.enabled, language: preference.language)
    }
}

/// One push per brief. The app routes `category` to the dashboard card and
/// opens the slot and date it names.
struct MarketBriefPushMessage: Sendable, Equatable {
    static let category = "MARKET_BRIEF"

    let slot: MarketBriefSlot
    let tradingDate: String
    let title: String
    let body: String

    var deepLink: String {
        "financeplan://market/brief?slot=\(slot.rawValue)&date=\(tradingDate)"
    }

    /// Nil when the brief has nothing worth a notification.
    init?(brief: MarketBriefResponse) {
        guard let slot = brief.slot, let tradingDate = brief.tradingDate,
              let first = brief.items.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              first.isEmpty == false
        else { return nil }
        self.slot = slot
        self.tradingDate = tradingDate
        let portuguese = MarketBriefLanguage.resolve(brief.language) == .ptPT
        title = switch slot {
        case .morning: portuguese ? "Briefing da manhã" : "Morning market brief"
        case .evening: portuguese ? "Resumo do fecho" : "Market close recap"
        }
        body = first.count > Self.maxBodyLength
            ? String(first.prefix(Self.maxBodyLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : first
    }

    /// Roughly what a lock screen shows before truncating anyway.
    static let maxBodyLength = 180
}

/// Fans a freshly written slot out to the users who opted in.
///
/// Called only by the job, and only when `MarketBriefRunner` reports
/// `.generated`: the unique (trading_date, slot, language) insert means one
/// process ever sees that outcome per slot, so a slot pushes at most once
/// without a ledger. Operator `--replace` runs do not push.
struct MarketBriefNotifier: Sendable {
    /// A brief that lands this long after its window opened is old news on a
    /// lock screen; the card still shows it.
    static let maxDelayMinutes = 90

    let repository: any MarketBriefRepository

    @discardableResult
    func notify(_ due: MarketBriefSchedule.Due, now: Date, on req: Request) async throws -> TargetPushSendSummary {
        let opened = due.slot == .morning ? MarketBriefSchedule.morningStart : MarketBriefSchedule.eveningStart
        guard MarketBriefSchedule.localMinutes(now) - opened <= Self.maxDelayMinutes else {
            req.logger.info("market_brief push skipped: late date=\(due.tradingDate) slot=\(due.slot.rawValue)")
            return .init(delivered: 0, failed: 0)
        }
        let preferences = try await MarketBriefNotificationPreference.query(on: req.db)
            .filter(\.$enabled == true)
            .all()
        var delivered = 0
        var failed = 0
        for language in MarketBriefLanguage.allCases {
            let userIds = preferences.filter { $0.language == language.rawValue }.map(\.userId)
            guard userIds.isEmpty == false,
                  let brief = try await repository.find(
                      tradingDate: due.tradingDate, slot: due.slot, language: language.rawValue, on: req.db
                  ),
                  let message = MarketBriefPushMessage(brief: brief)
            else { continue }
            let devices = try await PushDevice.query(on: req.db)
                .filter(\.$userId ~~ userIds)
                .filter(\.$isActive == true)
                .all()
            let summary = await req.application.pushNotificationSender.sendMarketBrief(
                message: message, devices: devices, req: req
            )
            delivered += summary.delivered
            failed += summary.failed
        }
        req.logger.info(
            "market_brief push date=\(due.tradingDate) slot=\(due.slot.rawValue) delivered=\(delivered) failed=\(failed)"
        )
        return .init(delivered: delivered, failed: failed)
    }
}
