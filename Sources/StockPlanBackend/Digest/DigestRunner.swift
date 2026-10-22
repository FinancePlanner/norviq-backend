import Fluent
import FluentSQL
import Foundation
import Vapor

/// Claims due digests, composes them and delivers them.
///
/// At most once, per digest and per channel. The `weekly_digests` row is
/// inserted before anything is read (unique on user and week), and each
/// channel's `weekly_digest_deliveries` row before anything is sent (unique on
/// digest and channel). A crash or a second replica therefore costs a missed
/// message, never a duplicate one: in a money email, silence is the cheaper
/// failure.
struct DigestRunner: Sendable {
    let config: DigestConfig
    let sources: any DigestDataSources

    struct Summary: Equatable, Sendable {
        var claimed = 0
        var sent = 0
        var failed = 0
    }

    enum Outcome: Equatable, Sendable {
        /// Already claimed for this period (by this or another run).
        case alreadyClaimed
        case sent(digestId: UUID)
        case failed(digestId: UUID)
    }

    /// One scheduler pass: every user whose send time has come, up to `maxPerTick`.
    func runDue(now: Date, on req: Request) async throws -> Summary {
        var summary = Summary()
        let preferences = try await DigestPreference.query(on: req.db)
            .filter(\.$emailEnabled == true)
            .sort(\.$userId)
            .all()
        for preference in preferences where summary.claimed < config.maxPerTick {
            guard config.allows(preference.userId), hasActiveChannel(preference),
                  let timeZone = TimeZone(identifier: preference.timezone),
                  let period = DigestSchedule.duePeriod(
                      now: now, timeZone: timeZone, weekday: preference.weekday, localHour: preference.localHour
                  )
            else { continue }
            guard try await DigestFactsCollector.isEligible(userId: preference.userId, on: req.db) else { continue }
            switch try await run(preference: preference, period: period, on: req) {
            case .alreadyClaimed:
                continue
            case .sent:
                summary.claimed += 1
                summary.sent += 1
            case .failed:
                summary.claimed += 1
                summary.failed += 1
            }
        }
        return summary
    }

    /// Claims, composes and delivers one user's digest for `period`.
    func run(preference: DigestPreference, period: DigestSchedule.Period, on req: Request) async throws -> Outcome {
        let userId = preference.userId
        guard let digestId = try await claimDigest(userId: userId, period: period, on: req.db) else {
            return .alreadyClaimed
        }

        let payload: DigestPayload
        do {
            let previous = try await previousPayload(userId: userId, before: period.start, on: req.db)
            payload = try await DigestFactsCollector(sources: sources)
                .collect(userId: userId, period: period, preference: preference, previous: previous, on: req)
            try await update(digestId, on: req.db) {
                $0.payload = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
                $0.status = WeeklyDigestStatus.composed.rawValue
            }
        } catch {
            req.logger.error("digest.compose_failed user=\(userId) period=\(period.start) error=\(String(describing: error))")
            try await update(digestId, on: req.db) {
                $0.status = WeeklyDigestStatus.failed.rawValue
                $0.error = String(String(describing: error).prefix(500))
            }
            return .failed(digestId: digestId)
        }

        var delivered = false
        if config.emailEnabled, preference.emailEnabled {
            delivered = await deliverEmail(digestId: digestId, payload: payload, preference: preference, on: req) || delivered
        }

        let status: WeeklyDigestStatus = delivered ? .sent : .failed
        try await update(digestId, on: req.db) { $0.status = status.rawValue }
        req.logger.info("digest.\(status.rawValue) user=\(userId) period=\(period.start) digest=\(digestId)")
        return delivered ? .sent(digestId: digestId) : .failed(digestId: digestId)
    }

    private func hasActiveChannel(_ preference: DigestPreference) -> Bool {
        config.emailEnabled && preference.emailEnabled
    }

    // MARK: - Email

    private func deliverEmail(
        digestId: UUID,
        payload: DigestPayload,
        preference: DigestPreference,
        on req: Request
    ) async -> Bool {
        do {
            guard let deliveryId = try await claimDelivery(digestId: digestId, channel: .email, on: req.db) else {
                return false
            }
            guard let user = try await User.find(preference.userId, on: req.db) else { return false }
            // Unverified addresses bounce, and bounces cost the domain that
            // also delivers MFA codes.
            guard user.emailVerifiedAt != nil else {
                try await finishDelivery(deliveryId, status: .failed, error: "email_unverified", on: req.db)
                return false
            }
            let rendered = DigestEmailRenderer(webBaseURL: config.webBaseURL, apiBaseURL: config.apiBaseURL)
                .render(digestId: digestId, payload: payload, unsubscribeToken: preference.unsubscribeToken)
            do {
                try await req.application.mailer.send(MailMessage(
                    to: user.email,
                    subject: rendered.subject,
                    body: rendered.text,
                    purpose: "weekly_digest",
                    htmlBody: rendered.html,
                    headers: rendered.headers
                ), on: req)
            } catch {
                try await finishDelivery(deliveryId, status: .failed, error: String(describing: error), on: req.db)
                return false
            }
            try await finishDelivery(deliveryId, status: .sent, error: nil, on: req.db)
            return true
        } catch {
            req.logger.error("digest.email_failed digest=\(digestId) error=\(String(describing: error))")
            return false
        }
    }

    // MARK: - Claims

    /// Inserts the week's row; nil when it already exists.
    func claimDigest(userId: UUID, period: DigestSchedule.Period, on db: any Database) async throws -> UUID? {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError, reason: "digest requires SQL") }
        let row = try await sql.raw("""
        INSERT INTO weekly_digests (id, user_id, period_start, period_end, status, created_at, updated_at)
        VALUES (\(bind: UUID()), \(bind: userId), \(bind: period.start), \(bind: period.end), \(bind: WeeklyDigestStatus.pending.rawValue), now(), now())
        ON CONFLICT (user_id, period_start) DO NOTHING
        RETURNING id
        """).first()
        return try row?.decode(column: "id", as: UUID.self)
    }

    private func claimDelivery(digestId: UUID, channel: DigestChannel, on db: any Database) async throws -> UUID? {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError, reason: "digest requires SQL") }
        let row = try await sql.raw("""
        INSERT INTO weekly_digest_deliveries (id, digest_id, channel, status, created_at)
        VALUES (\(bind: UUID()), \(bind: digestId), \(bind: channel.rawValue), \(bind: DigestDeliveryStatus.sending.rawValue), now())
        ON CONFLICT (digest_id, channel) DO NOTHING
        RETURNING id
        """).first()
        return try row?.decode(column: "id", as: UUID.self)
    }

    private func finishDelivery(_ id: UUID, status: DigestDeliveryStatus, error: String?, on db: any Database) async throws {
        guard let delivery = try await WeeklyDigestDelivery.find(id, on: db) else { return }
        delivery.status = status.rawValue
        delivery.error = error.map { String($0.prefix(500)) }
        if status == .sent { delivery.sentAt = Date() }
        try await delivery.save(on: db)
    }

    private func update(_ id: UUID, on db: any Database, _ change: (WeeklyDigest) throws -> Void) async throws {
        guard let digest = try await WeeklyDigest.find(id, on: db) else { return }
        try change(digest)
        try await digest.save(on: db)
    }

    private func previousPayload(userId: UUID, before periodStart: String, on db: any Database) async throws -> DigestPayload? {
        try await WeeklyDigest.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$periodStart < periodStart)
            .filter(\.$payload != nil)
            .sort(\.$periodStart, .descending)
            .first()?
            .decodedPayload()
    }
}
