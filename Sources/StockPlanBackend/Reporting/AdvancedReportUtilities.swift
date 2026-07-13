import Fluent
import Foundation
import StockPlanShared
import Vapor

func encodeReportJSON(_ value: some Encodable) throws -> String {
    let data = try JSONEncoder.backendAPI.encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
        throw Abort(.internalServerError, reason: "Failed to encode report configuration.")
    }
    return result
}

func decodeReportJSON<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONDecoder.backendAPI.decode(type, from: Data(value.utf8))
}

struct ReportRecurrenceCalculator: Sendable {
    func next(after date: Date, recurrence: ReportRecurrence) throws -> Date {
        guard let timeZone = TimeZone(identifier: recurrence.timeZone) else {
            throw Abort(.badRequest, reason: "Invalid report schedule time zone.")
        }
        let timeParts = recurrence.localTime.split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 2, (0 ... 23).contains(timeParts[0]), (0 ... 59).contains(timeParts[1]) else {
            throw Abort(.badRequest, reason: "localTime must use HH:mm.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch recurrence.frequency {
        case .weekly:
            guard let weekday = recurrence.weekday else {
                throw Abort(.badRequest, reason: "Weekly schedules require a weekday.")
            }
            var components = DateComponents()
            components.weekday = weekday.rawValue
            components.hour = timeParts[0]
            components.minute = timeParts[1]
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(7 * 86400)
        case .monthly, .quarterly, .yearly:
            guard let day = recurrence.dayOfMonth, (1 ... 31).contains(day) else {
                throw Abort(.badRequest, reason: "Monthly, quarterly, and yearly schedules require dayOfMonth.")
            }
            let monthStep = recurrence.frequency == .monthly ? 1 : (recurrence.frequency == .quarterly ? 3 : 12)
            var candidate = date
            for _ in 0 ..< 24 {
                candidate = calendar.date(byAdding: .month, value: monthStep, to: candidate)
                    ?? candidate.addingTimeInterval(TimeInterval(monthStep * 31 * 86400))
                var parts = calendar.dateComponents([.year, .month], from: candidate)
                if recurrence.frequency == .yearly, let anchor = recurrence.anchorMonth {
                    parts.month = min(max(anchor, 1), 12)
                }
                let maximumDay = calendar.range(of: .day, in: .month, for: candidate)?.count ?? 28
                parts.day = min(day, maximumDay)
                parts.hour = timeParts[0]
                parts.minute = timeParts[1]
                if let result = calendar.date(from: parts), result > date {
                    return result
                }
            }
            throw Abort(.badRequest, reason: "Could not calculate the next report run.")
        }
    }
}

struct AdvancedReportMapper: Sendable {
    func template(_ record: AdvancedReportTemplateRecord) throws -> ReportTemplate {
        try ReportTemplate(
            id: record.requireID().uuidString,
            ownerUserId: record.ownerUserId.uuidString,
            input: decodeReportJSON(ReportTemplateInput.self, record.inputJSON),
            revision: record.revision,
            isStarterTemplate: record.isStarterTemplate,
            archivedAt: formatISODateTime(record.archivedAt),
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    func schedule(_ record: AdvancedReportScheduleRecord) throws -> ReportSchedule {
        try ReportSchedule(
            id: record.requireID().uuidString,
            ownerUserId: record.ownerUserId.uuidString,
            input: decodeReportJSON(ReportScheduleInput.self, record.inputJSON),
            nextRunAt: formatISODateTime(record.nextRunAt),
            lastRunAt: formatISODateTime(record.lastRunAt),
            pausedReason: record.pausedReason,
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    func run(_ record: AdvancedReportRunRecord, on database: any Database) async throws -> ReportRun {
        let runId = try record.requireID()
        let artifacts = try await AdvancedReportArtifactRecord.query(on: database)
            .filter(\.$runId == runId)
            .sort(\.$createdAt, .ascending)
            .all()
            .compactMap(artifact)
        let deliveries = try await AdvancedReportDeliveryRecord.query(on: database)
            .filter(\.$runId == runId)
            .sort(\.$createdAt, .ascending)
            .all()
            .compactMap(delivery)
        return try ReportRun(
            id: runId.uuidString,
            templateId: record.templateId.uuidString,
            scheduleId: record.scheduleId?.uuidString,
            requestedByUserId: record.requestedByUserId.uuidString,
            templateRevision: record.templateRevision,
            outputFormats: decodeReportJSON([ReportOutputFormat].self, record.outputFormatsJSON),
            status: ReportRunStatus(rawValue: record.status) ?? .failed,
            scheduledFor: formatISODateTime(record.scheduledFor),
            startedAt: formatISODateTime(record.startedAt),
            completedAt: formatISODateTime(record.completedAt),
            failureReason: record.failureReason,
            artifacts: artifacts,
            deliveries: deliveries,
            createdAt: formatISODateTime(record.createdAt) ?? ""
        )
    }

    func artifact(_ record: AdvancedReportArtifactRecord) -> ReportArtifact? {
        guard let id = record.id else { return nil }
        return ReportArtifact(
            id: id.uuidString,
            runId: record.runId.uuidString,
            format: ReportOutputFormat(rawValue: record.format) ?? .pdf,
            filename: record.filename,
            contentType: record.contentType,
            sizeBytes: record.sizeBytes,
            sha256: record.sha256,
            downloadPath: "/v1/reporting/artifacts/\(id.uuidString)/download",
            expiresAt: formatISODateTime(record.expiresAt) ?? "",
            createdAt: formatISODateTime(record.createdAt) ?? ""
        )
    }

    func delivery(_ record: AdvancedReportDeliveryRecord) -> ReportDelivery? {
        guard let id = record.id else { return nil }
        return ReportDelivery(
            id: id.uuidString,
            runId: record.runId.uuidString,
            recipientUserId: record.recipientUserId.uuidString,
            recipientEmail: record.recipientEmail,
            status: ReportDeliveryStatus(rawValue: record.status) ?? .failed,
            attemptCount: record.attemptCount,
            lastAttemptAt: formatISODateTime(record.lastAttemptAt),
            deliveredAt: formatISODateTime(record.deliveredAt),
            failureReason: record.failureReason,
            linkExpiresAt: formatISODateTime(record.linkExpiresAt)
        )
    }
}
