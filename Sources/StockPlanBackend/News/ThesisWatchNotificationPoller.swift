import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

final class ThesisWatchNotificationPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = ThesisWatchNotificationPollerState()
    private var scheduled: RepeatedTask?

    init(intervalSeconds: Int64 = 900) {
        self.intervalSeconds = max(intervalSeconds, 300)
    }

    func didBoot(_ app: Application) throws {
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(120),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task { await self.tick(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel()
        scheduled = nil
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        guard await state.begin() else { return }
        defer { Task { await state.finish() } }

        do {
            let preferences = try await ThesisWatchNotificationPreference.query(on: app.db)
                .filter(\.$enabled == true)
                .all()
            for preference in preferences {
                try await deliver(for: preference, app: app)
            }
        } catch {
            app.logger.warning("thesis_watch_notifications failed error=\(String(describing: error))")
        }
    }

    private func deliver(for preference: ThesisWatchNotificationPreference, app: Application) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: preference.timezone) ?? .gmt
        let startOfDay = calendar.startOfDay(for: Date())
        var deliveredToday = try await NotificationEventModel.query(on: app.db)
            .filter(\.$userId == preference.userId)
            .filter(\.$kind == NotificationEventKind.thesisWatch.rawValue)
            .filter(\.$createdAt >= startOfDay)
            .count()
        guard deliveredToday < 3 else { return }

        let feed = try await app.thesisWatchService.feed(
            userId: preference.userId,
            scope: .forYou,
            sector: nil,
            limit: 50,
            cursor: nil,
            on: app.db
        )
        guard feed.capabilities.isPro else { return }
        let request = Request(application: app, on: app.eventLoopGroup.next())

        for story in feed.items where story.severity == .high || story.thesisImpact == .challenges {
            guard deliveredToday < 3 else { break }
            let key = "thesis-watch:\(story.id.lowercased())"
            let exists = try await NotificationEventModel.query(on: app.db)
                .filter(\.$userId == preference.userId)
                .filter(\.$deduplicationKey == key)
                .first() != nil
            guard !exists else { continue }

            let symbol = story.symbols.first ?? "Portfolio"
            let title = story.thesisImpact == .challenges
                ? "Thesis challenge: \(symbol)"
                : "Major event: \(symbol)"
            let body = story.whyItMatters ?? story.headline
            _ = try await NotificationEventPublisher.publishAndPush(
                userId: preference.userId,
                kind: .thesisWatch,
                deduplicationKey: key,
                title: title,
                body: String(body.prefix(220)),
                deepLink: "financeplan://portfolio/thesis-watch/\(story.id)",
                payload: ["storyId": story.id, "symbol": symbol],
                req: request
            )
            deliveredToday += 1
        }
    }
}

private actor ThesisWatchNotificationPollerState {
    private var isRunning = false

    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
    }
}
