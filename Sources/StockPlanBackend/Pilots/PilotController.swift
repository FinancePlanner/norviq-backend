import Fluent
import Foundation
import StockPlanShared
import Vapor

struct PilotController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.portfolioRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.portfolioWrite))
        read.get("pilots", use: listPilots)
        read.get("pilots", ":slug", use: pilotDetail)
        read.get("pilot-follows", use: listFollows)
        read.get("pilot-follows", ":followId", use: getFollow)
        read.get("pilot-follows", ":followId", "events", use: events)
        read.get("pilot-follows", ":followId", "snapshots", use: snapshots)
        write.post("pilot-follows", use: createFollow)
        write.patch("pilot-follows", ":followId", use: updateFollow)
        write.delete("pilot-follows", ":followId", use: deleteFollow)
    }

    @Sendable
    func listPilots(req: Request) async throws -> [PilotSummary] {
        try requireEnabled()
        let pilots = try await Pilot.query(on: req.db).filter(\.$active == true).sort(\.$displayName).all()
        var out: [PilotSummary] = []
        for pilot in pilots {
            try await out.append(summary(pilot, on: req.db))
        }
        return out
    }

    @Sendable
    func pilotDetail(req: Request) async throws -> PilotDetail {
        try requireEnabled()
        guard let slug = req.parameters.get("slug"),
              let pilot = try await Pilot.query(on: req.db).filter(\.$slug == slug).filter(\.$active == true).first()
        else { throw Abort(.notFound, reason: "Pilot not found.") }
        let latest = try await latestVersion(pilot, on: req.db)
        let recent = try await PilotDisclosureRecord.query(on: req.db)
            .filter(\.$pilotId == pilot.requireID())
            .sort(\.$transactionDate, .descending)
            .sort(\.$discoveredAt, .descending)
            .limit(25)
            .all()
        return try await PilotDetail(
            pilot: summary(pilot, on: req.db),
            weights: (latest?.weights ?? [:]).sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { PilotWeight(symbol: $0.key, weight: $0.value) },
            skippedPuts: latest?.skippedPuts ?? 0,
            recentDisclosures: recent.map {
                PilotDisclosureItem(symbol: $0.symbol, side: $0.side, instrument: $0.instrument, transactionDate: $0.transactionDate, disclosureDate: $0.disclosureDate, amountMin: $0.amountMin, amountMax: $0.amountMax, period: $0.period)
            },
            lagNote: Self.lagNote(for: pilot.pilotKind)
        )
    }

    @Sendable
    func listFollows(req: Request) async throws -> [PilotFollowResponse] {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let follows = try await PilotFollow.query(on: req.db).filter(\.$userId == session.userId).sort(\.$createdAt, .descending).all()
        var out: [PilotFollowResponse] = []
        for follow in follows {
            try await out.append(response(follow, on: req.db))
        }
        return out
    }

    @Sendable
    func getFollow(req: Request) async throws -> PilotFollowResponse {
        try requireEnabled()
        return try await response(ownedFollow(req), on: req.db)
    }

    @Sendable
    func createFollow(req: Request) async throws -> Response {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PilotFollowCreateRequest.self)
        // portfolio:write (the route) covers creating the follow; a token also
        // needs write access to what the follow fills.
        switch payload.targetKind {
        case .portfolio: try ScopeRequirementMiddleware.require(.holdingsWrite, on: req)
        case .watchlist: try ScopeRequirementMiddleware.require(.watchlistWrite, on: req)
        }
        let entitlement = try await req.entitlementResolver.resolve(userId: session.userId, on: req.db)
        let follow = try await PilotFollowService(mirror: PilotWiring.mirror(req.application))
            .create(payload, userId: session.userId, entitlement: entitlement, now: Date(), on: req.db)
        return try await response(follow, on: req.db).encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateFollow(req: Request) async throws -> PilotFollowResponse {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        let payload = try req.content.decode(PilotFollowUpdateRequest.self)
        follow.status = payload.status.rawValue
        try await follow.save(on: req.db)
        return try await response(follow, on: req.db)
    }

    /// Stops the follow. The portfolio or watchlist it wrote to is kept: those
    /// are the user's now.
    @Sendable
    func deleteFollow(req: Request) async throws -> HTTPStatus {
        try requireEnabled()
        try await ownedFollow(req).delete(on: req.db)
        return .noContent
    }

    @Sendable
    func events(req: Request) async throws -> [PilotFollowEventResponse] {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        return try await PilotFollowEvent.query(on: req.db)
            .filter(\.$followId == follow.requireID())
            .sort(\.$bookVersion, .descending)
            .sort(\.$symbol)
            .limit(500)
            .all()
            .map {
                try PilotFollowEventResponse(id: $0.requireID().uuidString, bookVersion: $0.bookVersion, kind: $0.kind, symbol: $0.symbol, quantity: $0.quantity, price: $0.price, pricedAt: Self.iso($0.pricedAt), note: $0.note)
            }
    }

    @Sendable
    func snapshots(req: Request) async throws -> [PilotFollowSnapshotResponse] {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        return try await PilotFollowSnapshot.query(on: req.db)
            .filter(\.$followId == follow.requireID())
            .sort(\.$capturedOn)
            .all()
            .map { PilotFollowSnapshotResponse(date: Self.day($0.capturedOn), value: $0.value, cash: $0.cash) }
    }

    // MARK: - Helpers

    static func lagNote(for kind: PilotKind) -> String {
        switch kind {
        case .politician:
            "Congressional trades are disclosed up to 45 days after they happen. Simulated trades are priced when Norviq sees the disclosure, not on the original trade date. No real money is invested."
        case .fund:
            "13F filings arrive up to 135 days after the positions they report. Simulated trades are priced when Norviq sees the filing. No real money is invested."
        }
    }

    private func requireEnabled() throws {
        guard envBool("PILOTS_ENABLED", default: false) else { throw Abort(.notFound) }
    }

    private func ownedFollow(_ req: Request) async throws -> PilotFollow {
        let session = try req.auth.require(SessionToken.self)
        guard let raw = req.parameters.get("followId"), let id = UUID(uuidString: raw),
              let follow = try await PilotFollow.query(on: req.db).filter(\.$id == id).filter(\.$userId == session.userId).first()
        else { throw Abort(.notFound, reason: "Follow not found.") }
        return follow
    }

    private func latestVersion(_ pilot: Pilot, on db: any Database) async throws -> PilotBookVersion? {
        try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilot.requireID()).sort(\.$version, .descending).first()
    }

    private func summary(_ pilot: Pilot, on db: any Database) async throws -> PilotSummary {
        let latest = try await latestVersion(pilot, on: db)
        return PilotSummary(slug: pilot.slug, displayName: pilot.displayName, kind: pilot.pilotKind, chamber: pilot.chamber, updatedAt: latest.map { Self.iso($0.computedAt) }, holdingsCount: latest?.weights.count ?? 0)
    }

    private func response(_ follow: PilotFollow, on db: any Database) async throws -> PilotFollowResponse {
        guard let pilot = try await Pilot.find(follow.pilotId, on: db) else { throw Abort(.notFound, reason: "Pilot not found.") }
        return try await PilotFollowResponse(
            id: follow.requireID().uuidString,
            pilot: summary(pilot, on: db),
            targetKind: follow.target,
            portfolioListId: follow.portfolioListId?.uuidString,
            watchlistListId: follow.watchlistListId?.uuidString,
            startingCapital: follow.startingCapital,
            currency: follow.currency,
            status: PilotFollowStatus(rawValue: follow.status) ?? .active,
            appliedVersion: follow.appliedVersion,
            createdAt: Self.iso(follow.createdAt ?? Date())
        )
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
