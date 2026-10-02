import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Builds the live services from the app's configured providers.
enum PilotWiring {
    static func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    /// Free sources only: FMP's latest congress feeds (page 0, 25 rows) and
    /// SEC EDGAR 13F filings with OpenFIGI CUSIP mapping.
    static func ingestion(_ app: Application) -> PilotIngestionService? {
        guard let fmp = app.marketDataService.fmpProvider else { return nil }
        let congress = FMPCongressPilotSource { chamber in
            let req = request(app)
            return chamber == "senate"
                ? try await fmp.latestSenateTrades(limit: FMPCongressPilotSource.feedLimit, on: req)
                : try await fmp.latestHouseTrades(limit: FMPCongressPilotSource.feedLimit, on: req)
        }
        let userAgent = Environment.get("SEC_EDGAR_USER_AGENT") ?? "Norviq ops@norviq.org"
        let resolver = CusipSymbolResolver(
            post: { body in
                let response = try await app.client.post("https://api.openfigi.com/v3/mapping") { req in
                    req.headers.replaceOrAdd(name: .contentType, value: "application/json")
                    req.body = ByteBuffer(data: body)
                    req.timeout = .seconds(30)
                }
                guard response.status == .ok, let buffer = response.body else {
                    throw Abort(.badGateway, reason: "OpenFIGI returned \(response.status.code)")
                }
                return Data(buffer: buffer)
            },
            pause: { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        )
        let funds = SECEdgar13FPilotSource(
            get: { url in
                let response = try await app.client.get(URI(string: url)) { req in
                    req.headers.replaceOrAdd(name: .userAgent, value: userAgent)
                    req.timeout = .seconds(30)
                }
                guard response.status == .ok, let buffer = response.body else {
                    throw Abort(.badGateway, reason: "EDGAR returned \(response.status.code) for \(url)")
                }
                return Data(buffer: buffer)
            },
            resolve: { cusips in try await resolver.resolve(cusips, on: app.db) }
        )
        return PilotIngestionService(politicians: congress, funds: funds)
    }

    static func mirror(_ app: Application) -> PilotMirrorService {
        PilotMirrorService(
            quote: { symbol in try await app.marketDataService.quote(symbol: symbol, on: request(app)).currentPrice },
            instrument: { symbol in
                try? await CsvPortfolioImportService().manualEntryInstrument(symbol: symbol, on: request(app), db: app.db).id
            },
            watchlistLimit: { userId, current, db in
                try await app.usageCounterService.enforceResourceLimit(.watchlistItems, userId: userId, currentCount: current, adding: 1, on: db)
            }
        )
    }
}

/// Pulls disclosures for every active pilot. Hourly, because the free congress
/// feed shows only the newest 25 rows per chamber and older rows scroll off.
/// Funds file quarterly, so each fund is read at most once a day.
final class PilotIngestionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = BackgroundJobState()

    static let fundRefreshSeconds: TimeInterval = 86400

    init(intervalSeconds: Int64 = 3600) {
        self.intervalSeconds = max(900, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(240), delay: .seconds(intervalSeconds)) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                guard let service = PilotWiring.ingestion(app) else { return }
                _ = await JobLock.runAsLeader(app, name: "pilot_ingestion_job") {
                    await self.runOnceAsLeader(app, service: service)
                }
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func runOnceAsLeader(_ app: Application, service: PilotIngestionService) async {
        do {
            let pilots = try await Pilot.query(on: app.db).filter(\.$active == true).all()
            let now = Date()
            for pilot in pilots where !Task.isCancelled {
                if pilot.pilotKind == .fund, let last = pilot.lastIngestedAt,
                   now.timeIntervalSince(last) < Self.fundRefreshSeconds
                {
                    continue
                }
                do {
                    let outcome = try await service.ingest(pilot: pilot, now: now, on: app.db)
                    if case let .newVersion(v) = outcome {
                        app.logger.info("pilot_ingestion new_version", metadata: ["pilot": .string(pilot.slug), "version": .stringConvertible(v)])
                    }
                } catch {
                    app.logger.warning("pilot_ingestion failed", metadata: ["pilot": .string(pilot.slug), "error": .string(String(reflecting: error))])
                }
            }
        } catch {
            app.logger.error("pilot_ingestion run failed", metadata: ["error": .string(String(reflecting: error))])
        }
    }
}

/// Brings every active follow up to its pilot's latest book, then records one
/// value snapshot per follow per day. It applies only the latest version, never
/// the ones in between: rebalancing works from current holdings, so skipping
/// a version loses nothing.
final class PilotMirrorJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64 = 3600) {
        self.intervalSeconds = max(300, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(300), delay: .seconds(intervalSeconds)) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                let mirror = PilotWiring.mirror(app)
                _ = await JobLock.runAsLeader(app, name: "pilot_mirror_job") {
                    await self.runOnceAsLeader(app, mirror: mirror, now: Date())
                }
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func runOnceAsLeader(_ app: Application, mirror: PilotMirrorService, now: Date) async {
        do {
            let follows = try await PilotFollow.query(on: app.db).filter(\.$status == PilotFollowStatus.active.rawValue).all()
            for follow in follows where !Task.isCancelled {
                do {
                    try await catchUp(follow, mirror: mirror, now: now, on: app.db)
                    if follow.target == .portfolio {
                        try await snapshot(follow, now: now, logger: app.logger, on: app.db)
                    }
                } catch {
                    app.logger.warning("pilot_mirror failed", metadata: ["follow_id": .string(follow.id?.uuidString ?? "?"), "error": .string(String(reflecting: error))])
                }
            }
        } catch {
            app.logger.error("pilot_mirror run failed", metadata: ["error": .string(String(reflecting: error))])
        }
    }

    private func catchUp(_ follow: PilotFollow, mirror: PilotMirrorService, now: Date, on db: any Database) async throws {
        guard let pilot = try await Pilot.find(follow.pilotId, on: db),
              let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == follow.pilotId).sort(\.$version, .descending).first(),
              latest.version > follow.appliedVersion
        else { return }
        let previous = follow.appliedVersion > 0
            ? try await PilotBookVersion.query(on: db).filter(\.$pilotId == follow.pilotId).filter(\.$version == follow.appliedVersion).first()
            : nil
        if try await mirror.apply(follow: follow, pilot: pilot, version: latest, previous: previous, now: now, on: db) {
            follow.appliedVersion = latest.version
        }
    }

    /// One row per follow per day. Kept apart from portfolio_value_snapshots
    /// on purpose: that table holds only real portfolios.
    private func snapshot(_ follow: PilotFollow, now: Date, logger: Logger, on db: any Database) async throws {
        guard let listId = follow.portfolioListId else { return }
        let day = PortfolioSnapshotValuator.startOfDay(now)
        let exists = try await PilotFollowSnapshot.query(on: db).filter(\.$followId == follow.requireID()).filter(\.$capturedOn == day).first()
        guard exists == nil else { return }
        let valuation = try await PortfolioSnapshotValuator().value(userId: follow.userId, portfolioListId: listId, asOf: now, pricing: .live, on: db)
        guard valuation.isFullyPriced else {
            // Writing now would pin a partial value for the day (the exists-check
            // above blocks later correction), so skip and let a later tick retry.
            logger.warning("pilot_snapshot skipped: incomplete pricing", metadata: [
                "follow_id": .string(follow.id?.uuidString ?? "?"),
                "missing": .stringConvertible(valuation.missingSymbols),
            ])
            return
        }
        try await PilotFollowSnapshot(followId: follow.requireID(), capturedOn: day, value: valuation.totalValue, cash: valuation.cashBalance).create(on: db)
    }
}
