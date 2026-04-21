import Fluent
import Foundation
import Vapor

protocol TrialServicing: Sendable {
    func initializeTrial(
        user: User,
        trialDays: Int,
        tierName: String,
        db: any Database
    ) async throws

    func checkTrialStatus(user: User) -> TrialStatus

    func isTrialExpired(user: User) -> Bool

    func getDaysRemaining(user: User) -> Int?

    func processExpiredTrials(db: any Database) async throws -> [UUID]

    func sendExpiringWarning(
        user: User,
        db: any Database
    ) async throws -> Bool

    func markTrialExpired(user: User, db: any Database) async throws
}

enum TrialStatus {
    case active(daysRemaining: Int)
    case expiringSoon(daysRemaining: Int)
    case expired
    case notOnTrial
}

struct TrialService: TrialServicing {
    private let warnDaysBeforeExpiry: Int

    init(warnDaysBeforeExpiry: Int = 3) {
        self.warnDaysBeforeExpiry = warnDaysBeforeExpiry
    }

    func initializeTrial(
        user: User,
        trialDays: Int,
        tierName: String,
        db: any Database
    ) async throws {
        guard (1...31).contains(trialDays) else {
            throw Abort(.badRequest, reason: "Trial duration is invalid.")
        }
        user.trialStartedAt = Date()
        user.trialDays = trialDays
        user.trialTier = tierName
        try await user.save(on: db)
    }

    func checkTrialStatus(user: User) -> TrialStatus {
        guard let startedAt = user.trialStartedAt, let days = user.trialDays, user.trialTier != nil else {
            return .notOnTrial
        }

        let expiresAt = startedAt.addingTimeInterval(TimeInterval(days * 86400))
        let now = Date()
        let secondsRemaining = expiresAt.timeIntervalSince(now)
        let daysRemaining = Int(ceil(secondsRemaining / 86400))

        if secondsRemaining <= 0 {
            return .expired
        } else if daysRemaining <= warnDaysBeforeExpiry {
            return .expiringSoon(daysRemaining: max(0, daysRemaining))
        } else {
            return .active(daysRemaining: daysRemaining)
        }
    }

    func isTrialExpired(user: User) -> Bool {
        guard let startedAt = user.trialStartedAt, let days = user.trialDays, user.trialTier != nil else {
            return false
        }

        let expiresAt = startedAt.addingTimeInterval(TimeInterval(days * 86400))
        return Date() >= expiresAt
    }

    func getDaysRemaining(user: User) -> Int? {
        guard let startedAt = user.trialStartedAt, let days = user.trialDays, user.trialTier != nil else {
            return nil
        }

        let expiresAt = startedAt.addingTimeInterval(TimeInterval(days * 86400))
        let secondsRemaining = expiresAt.timeIntervalSince(Date())
        return Int(max(0, ceil(secondsRemaining / 86400)))
    }

    func processExpiredTrials(db: any Database) async throws -> [UUID] {
        let candidates = try await User.query(on: db)
            .filter(\.$trialTier != nil)
            .filter(\.$trialStartedAt != nil)
            .filter(\.$trialDays != nil)
            .limit(500)
            .all()

        let now = Date()
        var expiredUserIDs: [UUID] = []
        for user in candidates {
            guard let startedAt = user.trialStartedAt, let days = user.trialDays else {
                continue
            }
            let expiresAt = startedAt.addingTimeInterval(TimeInterval(days * 86400))
            if now >= expiresAt {
                try await markTrialExpired(user: user, db: db)
                if let id = user.id {
                    expiredUserIDs.append(id)
                }
            }
        }

        return expiredUserIDs
    }

    func sendExpiringWarning(
        user: User,
        db: any Database
    ) async throws -> Bool {
        guard let userID = user.id else { return false }

        let existingWarning = try await TrialWarning.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$warningType == .expiringSoon)
            .first()

        if existingWarning != nil {
            return false
        }

        let warning = TrialWarning(
            userID: userID,
            warningType: .expiringSoon,
            sentAt: Date()
        )
        try await warning.save(on: db)
        user.trialWarningSentAt = Date()
        try await user.save(on: db)

        return true
    }

    func markTrialExpired(user: User, db: any Database) async throws {
        guard let userID = user.id else { return }

        let existingWarning = try await TrialWarning.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$warningType == .expired)
            .first()

        user.trialTier = nil
        user.trialStartedAt = nil
        user.trialDays = nil
        user.hadTrial = true
        try await user.save(on: db)

        if existingWarning == nil {
            let warning = TrialWarning(
                userID: userID,
                warningType: .expired,
                sentAt: Date()
            )
            try await warning.save(on: db)
        }
    }
}

extension Application {
    private struct TrialServiceKey: StorageKey {
        typealias Value = any TrialServicing
    }

    var trialService: any TrialServicing {
        get {
            guard let service = storage[TrialServiceKey.self] else {
                return TrialService()
            }
            return service
        }
        set {
            storage[TrialServiceKey.self] = newValue
        }
    }
}
