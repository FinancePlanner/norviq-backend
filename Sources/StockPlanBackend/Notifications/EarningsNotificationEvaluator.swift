import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol EarningsNotificationEvaluating: Sendable {
    func evaluateUpcomingEarnings(req: Request) async
}

struct DefaultEarningsNotificationEvaluator: EarningsNotificationEvaluating {
    private static let leadDays = [7, 1]

    func evaluateUpcomingEarnings(req: Request) async {
        for leadDays in Self.leadDays {
            await evaluate(leadDays: leadDays, req: req)
        }
    }

    private func evaluate(leadDays: Int, req: Request) async {
        let targetDate = Self.targetDateString(leadDays: leadDays)

        let events: [EarningsItemResponse]
        do {
            events = try await req.application.earningsService.getCalendar(
                query: .init(from: targetDate, to: targetDate),
                on: req
            )
        } catch {
            req.logger.warning(
                "earnings-reminder calendar lookup failed date=\(targetDate) leadDays=\(leadDays) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        let symbols = Set(events.compactMap { Self.normalizedSymbol($0.symbol) })
        guard !symbols.isEmpty else {
            return
        }

        for symbol in symbols {
            await evaluate(symbol: symbol, earningsDate: targetDate, leadDays: leadDays, req: req)
        }
    }

    private func evaluate(symbol: String, earningsDate: String, leadDays: Int, req: Request) async {
        let userIds: Set<UUID>
        do {
            userIds = try await eligibleUserIds(symbol: symbol, on: req.db)
        } catch {
            req.logger.warning(
                "earnings-reminder eligible user lookup failed symbol=\(symbol) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        guard !userIds.isEmpty else {
            return
        }

        for userId in userIds {
            await evaluate(
                userId: userId,
                symbol: symbol,
                earningsDate: earningsDate,
                leadDays: leadDays,
                req: req
            )
        }
    }

    private func evaluate(
        userId: UUID,
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        req: Request
    ) async {
        do {
            try await req.usageCounterService.requirePremium(.targetAlerts, userId: userId, on: req.db)
        } catch {
            return
        }

        do {
            guard try await preferenceEnabled(userId: userId, on: req.db) else {
                return
            }

            guard try await shouldSend(userId: userId, symbol: symbol, earningsDate: earningsDate, leadDays: leadDays, on: req.db) else {
                return
            }
        } catch {
            req.logger.warning(
                "earnings-reminder state lookup failed userId=\(userId.uuidString) symbol=\(symbol) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        let devices: [PushDevice]
        do {
            devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
        } catch {
            req.logger.warning(
                "earnings-reminder device lookup failed userId=\(userId.uuidString) symbol=\(symbol) error_type=\(String(reflecting: type(of: error)))"
            )
            return
        }

        guard !devices.isEmpty else {
            return
        }

        let summary = await req.application.pushNotificationSender.sendEarningsReminder(
            symbol: symbol,
            earningsDate: earningsDate,
            leadDays: leadDays,
            devices: devices,
            req: req
        )

        guard summary.delivered > 0 else {
            return
        }

        do {
            try await recordDelivery(userId: userId, symbol: symbol, earningsDate: earningsDate, leadDays: leadDays, on: req.db)
        } catch {
            req.logger.warning(
                "earnings-reminder delivery record failed userId=\(userId.uuidString) symbol=\(symbol) earningsDate=\(earningsDate) leadDays=\(leadDays) error_type=\(String(reflecting: type(of: error)))"
            )
        }
    }

    private func eligibleUserIds(symbol: String, on db: any Database) async throws -> Set<UUID> {
        let stockUserIds = try await Stock.query(on: db)
            .filter(\.$symbol == symbol)
            .all()
            .map(\.userId)

        let watchlistUserIds = try await WatchlistItem.query(on: db)
            .filter(\.$symbol == symbol)
            .filter(\.$status == WatchlistStatus.active.rawValue)
            .all()
            .map(\.userId)

        return Set(stockUserIds + watchlistUserIds)
    }

    private func preferenceEnabled(userId: UUID, on db: any Database) async throws -> Bool {
        let preference = try await EarningsNotificationPreference.query(on: db)
            .filter(\.$userId == userId)
            .first()
        return preference?.enabled ?? true
    }

    private func shouldSend(
        userId: UUID,
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        on db: any Database
    ) async throws -> Bool {
        let existing = try await EarningsNotificationDelivery.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$symbol == symbol)
            .filter(\.$earningsDate == earningsDate)
            .filter(\.$leadDays == leadDays)
            .first()
        return existing == nil
    }

    private func recordDelivery(
        userId: UUID,
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        on db: any Database
    ) async throws {
        let delivery = EarningsNotificationDelivery(
            userId: userId,
            symbol: symbol,
            earningsDate: earningsDate,
            leadDays: leadDays
        )
        try await delivery.save(on: db)
    }

    private static func targetDateString(leadDays: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let now = Date()
        let target = calendar.date(byAdding: .day, value: leadDays, to: now) ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: target)
    }

    private static func normalizedSymbol(_ value: String?) -> String? {
        guard let value else { return nil }
        let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return symbol.isEmpty ? nil : symbol
    }
}

extension Application {
    private struct EarningsNotificationEvaluatorKey: StorageKey {
        typealias Value = any EarningsNotificationEvaluating
    }

    var earningsNotificationEvaluator: any EarningsNotificationEvaluating {
        get {
            guard let evaluator = storage[EarningsNotificationEvaluatorKey.self] else {
                fatalError("EarningsNotificationEvaluating not configured")
            }
            return evaluator
        }
        set {
            storage[EarningsNotificationEvaluatorKey.self] = newValue
        }
    }
}
