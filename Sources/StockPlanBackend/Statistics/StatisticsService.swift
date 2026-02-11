import Vapor
import Fluent
import Foundation

struct StatisticsQueryInput: Sendable {
    let period: String?
    let top: Int?
    let benchmark: String?
    let asOf: String?
}

protocol StatisticsService: Sendable {
    func stockLevelScorecard(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func stockAllocation(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func sectorAllocation(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func calendarPerformance(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func contributionAnalysis(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func winnersVsLosers(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func volatilitySnapshot(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func currencySplit(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func scenarioTracking(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func notesQualityMetrics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func importedStocksStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func watchlistStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func looklistStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func marketStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
    func overviewStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO
}

struct DefaultStatisticsService: StatisticsService {
    let repo: any StatisticsRepository

    func stockLevelScorecard(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.stockLevelScorecard(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func stockAllocation(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.stockAllocation(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func sectorAllocation(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.sectorAllocation(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func calendarPerformance(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.calendarPerformance(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func contributionAnalysis(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.contributionAnalysis(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func winnersVsLosers(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.winnersVsLosers(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func volatilitySnapshot(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.volatilitySnapshot(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func currencySplit(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.currencySplit(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func scenarioTracking(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.scenarioTracking(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func notesQualityMetrics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.notesQualityMetrics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func importedStocksStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.importedStocksStatistics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func watchlistStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.watchlistStatistics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func looklistStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.looklistStatistics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func marketStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.marketStatistics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }

    func overviewStatistics(userId: UUID, query: StatisticsQueryInput, on db: any Database) async throws -> StatisticsDTO {
        let options = try buildOptions(from: query)
        let model = try await repo.overviewStatistics(userId: userId, options: options, on: db)
        return StatisticsDTO(from: model)
    }
}

private extension DefaultStatisticsService {
    func buildOptions(from input: StatisticsQueryInput) throws -> StatisticsQueryOptions {
        let period = try parsePeriod(input.period)
        let top = try parseTop(input.top)
        let benchmark = try parseBenchmark(input.benchmark)
        let asOfDate = try parseAsOfDate(input.asOf)

        return StatisticsQueryOptions(
            period: period,
            top: top,
            benchmarkSymbol: benchmark,
            asOfDate: asOfDate
        )
    }

    func parsePeriod(_ raw: String?) throws -> StatisticsPeriod {
        guard let raw else { return .oneMonth }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return .oneMonth }

        switch normalized {
        case "1w", "7d", "week":
            return .oneWeek
        case "1m", "30d", "month":
            return .oneMonth
        case "3m", "90d":
            return .threeMonths
        case "6m", "180d":
            return .sixMonths
        case "1y", "12m", "365d", "year":
            return .oneYear
        case "ytd":
            return .ytd
        case "all":
            return .all
        default:
            throw Abort(
                .badRequest,
                reason: "Invalid `period`. Use one of: 1w, 1m, 3m, 6m, 1y, ytd, all."
            )
        }
    }

    func parseTop(_ raw: Int?) throws -> Int {
        let resolved = raw ?? 10
        guard (1...100).contains(resolved) else {
            throw Abort(.badRequest, reason: "Invalid `top`. Must be between 1 and 100.")
        }
        return resolved
    }

    func parseBenchmark(_ raw: String?) throws -> String {
        let symbol = (raw ?? "SPY")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !symbol.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid `benchmark`. Benchmark symbol is required.")
        }
        guard symbol.range(of: #"^[A-Z0-9.\-]{1,15}$"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid `benchmark`. Use a valid symbol like SPY.")
        }
        return symbol
    }

    func parseAsOfDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid `asOf`. Expected YYYY-MM-DD.")
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false

        guard let parsed = formatter.date(from: trimmed) else {
            throw Abort(.badRequest, reason: "Invalid `asOf`. Expected YYYY-MM-DD.")
        }

        if startOfDay(parsed) > startOfDay(Date()) {
            throw Abort(.badRequest, reason: "`asOf` cannot be in the future.")
        }
        return parsed
    }

    func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: date)
    }
}
