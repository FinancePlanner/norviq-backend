import Fluent
import Foundation
import Vapor

/// Fills one slot. Shared by the scheduled job and the operator command.
struct MarketBriefRunner: Sendable {
    enum Outcome: Equatable, Sendable {
        case skippedExisting
        case generated(degraded: Bool)
    }

    let generator: any MarketBriefGenerating
    let repository: any MarketBriefRepository

    func run(_ due: MarketBriefSchedule.Due, replace: Bool, on req: Request) async throws -> Outcome {
        if replace {
            try await repository.delete(tradingDate: due.tradingDate, slot: due.slot, on: req.db)
        } else if try await repository.exists(tradingDate: due.tradingDate, slot: due.slot, on: req.db) {
            return .skippedExisting
        }
        let brief = try await generator.generate(due, on: req)
        do {
            try await repository.save(brief.responses, model: brief.model, generatedAt: Date(), on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Another replica (or a manual run) wrote the slot while we were
            // generating. Theirs stands; this is not a failure to retry.
            return .skippedExisting
        }
        return .generated(degraded: brief.responses.contains(where: \.degraded))
    }
}
