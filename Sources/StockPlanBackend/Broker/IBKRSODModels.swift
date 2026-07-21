import Foundation
import Vapor

/// Configuration for IBKR Norviq Web Service (SOD) pulls.
/// Contract: `Documentation/ibkr-norviq-web-service.md`
struct IBKRSODConfiguration: Sendable, Equatable {
    var baseURL: String
    var serviceCode: String

    static let defaultBaseURL = "https://ndcdyn.interactivebrokers.com/Reporting/IBRITService"
    /// Exact service code from IBKR email (includes space before `-ws`).
    static let defaultServiceCode = "norviq -ws"

    static func fromEnvironment() -> IBKRSODConfiguration {
        let base = Environment.get("IBKR_SOD_BASE_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Environment.get("IBKR_SOD_SERVICE_CODE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IBKRSODConfiguration(
            baseURL: (base?.isEmpty == false) ? base! : defaultBaseURL,
            serviceCode: (code?.isEmpty == false) ? code! : defaultServiceCode
        )
    }
}

enum IBKRSODErrorCode: Int, Sendable, Equatable {
    case missingParameters = 1050
    case invalidTokenOrQuery = 1052
    case invalidServiceCode = 1053
    case serviceNotEnabled = 1054
    case dateInFuture = 1055
    case invalidDateFormat = 1056
    case noStatement = 1010
    case rateLimited = 1018
    case generationInProgress = 1019
}

enum IBKRSODError: Error, Equatable {
    case missingCredentials
    case invalidConfiguration(String)
    case httpStatus(Int, body: String)
    case service(IBKRSODErrorCode, detail: String)
    case emptyResponse
    case unsupportedPayload(String)
}

extension IBKRSODError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .missingCredentials, .invalidConfiguration:
            .badRequest
        case .service(.invalidTokenOrQuery, _), .service(.invalidServiceCode, _), .service(.serviceNotEnabled, _):
            .unauthorized
        case .service(.rateLimited, _), .service(.generationInProgress, _):
            .tooManyRequests
        case .service(.noStatement, _), .service(.dateInFuture, _), .service(.invalidDateFormat, _),
             .service(.missingParameters, _):
            .badRequest
        case .httpStatus, .emptyResponse, .unsupportedPayload:
            .badGateway
        }
    }

    var reason: String {
        switch self {
        case .missingCredentials:
            "IBKR Web Service token and query ID are required."
        case let .invalidConfiguration(message):
            message
        case let .httpStatus(code, _):
            "IBKR Web Service request failed (HTTP \(code))."
        case let .service(code, detail):
            userFacingMessage(for: code, detail: detail)
        case .emptyResponse:
            "IBKR Web Service returned an empty response."
        case let .unsupportedPayload(message):
            message
        }
    }

    private func userFacingMessage(for code: IBKRSODErrorCode, detail _: String) -> String {
        switch code {
        case .missingParameters:
            "IBKR statement request was incomplete. Please try again."
        case .invalidTokenOrQuery:
            "IBKR token or query ID is invalid."
        case .invalidServiceCode:
            "IBKR service code is invalid. Contact support."
        case .serviceNotEnabled:
            "IBKR Web Service is not enabled for this account yet."
        case .dateInFuture:
            "IBKR statement date cannot be in the future."
        case .invalidDateFormat:
            "IBKR statement date format is invalid."
        case .noStatement:
            "No IBKR statement is available for that date yet."
        case .rateLimited:
            "IBKR rate limit reached. Wait a moment and try again."
        case .generationInProgress:
            "IBKR is still generating the statement. Wait, then retry the same date."
        }
    }
}

enum IBKRSODReportDate {
    /// Formats `Date` as `yyyymmdd` in the given timezone (IBKR SOD window is ~2AM EDT).
    static func format(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "America/New_York")!) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Previous weekday on the America/New_York calendar (skips Sat/Sun).
    static func previousBusinessDay(
        from date: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "America/New_York")!
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var cursor = calendar.startOfDay(for: date)
        repeat {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        } while calendar.isDateInWeekend(cursor)
        return cursor
    }
}

struct IBKRSODFetchResult: Sendable, Equatable {
    let reportDate: String
    let files: [IBKRSODFilePayload]
}

struct IBKRSODFilePayload: Sendable, Equatable {
    let name: String
    let csvText: String
}
