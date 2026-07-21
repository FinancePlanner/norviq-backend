import Fluent
import Foundation
import Vapor

/// Fetches + parses IBKR SOD Web Service statements for connections marked `sod-web-service`.
///
/// Ingest into lots/positions is intentionally **not** enabled until live file-layout
/// fixtures validate provisional column aliases (`IBKR_SOD_INGEST_ENABLED=true` later).
struct IBKRSODSyncService: Sendable {
    let client: IBKRSODClient
    let parser: IBKRSODStatementParser
    let tokenVault: any TokenEncryptionService

    init(
        client: IBKRSODClient = IBKRSODClient(),
        parser: IBKRSODStatementParser = IBKRSODStatementParser(),
        tokenVault: any TokenEncryptionService
    ) {
        self.client = client
        self.parser = parser
        self.tokenVault = tokenVault
    }

    func sync(connection: BrokerConnection, userId _: UUID, on req: Request) async throws -> BrokerSyncResponse {
        guard connection.externalId == IBKRConnectMarkers.sodWebService else {
            throw Abort(.badRequest, reason: "Connection is not an IBKR Web Service (SOD) connection.")
        }

        let token = try decryptRequired(connection.accessToken, field: "token")
        let queryId = try decryptRequired(connection.refreshToken, field: "queryId")

        let reportDay = IBKRSODReportDate.previousBusinessDay()
        let reportDate = IBKRSODReportDate.format(reportDay)

        do {
            let fetch = try await client.fetch(
                token: token,
                queryId: queryId,
                reportDate: reportDate,
                on: req
            )
            let parsed = try parser.parse(fetch: fetch)
            let ingestEnabled = Environment.get("IBKR_SOD_INGEST_ENABLED")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "true"

            let detail = if ingestEnabled {
                "SOD \(reportDate): parsed \(parsed.provisionalPositions.count) position rows, \(parsed.provisionalActivities.count) activity rows. Ingest path not implemented yet."
            } else {
                "SOD \(reportDate): fetched OK — \(parsed.fileSummaries.map(\.fileName).joined(separator: ", ")). \(parsed.provisionalPositions.count) provisional positions, \(parsed.provisionalActivities.count) activities (ingest disabled until fixtures validated)."
            }

            connection.status = "connected"
            connection.statusDetail = detail
            connection.lastSyncedAt = Date()
            connection.updatedAt = Date()
            try await connection.save(on: req.db)

            return BrokerSyncResponse(
                runId: UUID().uuidString,
                status: "completed",
                inserted: 0,
                updated: 0,
                removed: 0
            )
        } catch let error as IBKRSODError {
            connection.status = "error"
            connection.statusDetail = error.reason
            connection.updatedAt = Date()
            try? await connection.save(on: req.db)
            throw error
        }
    }

    private func decryptRequired(_ stored: String?, field _: String) throws -> String {
        guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else {
            throw IBKRSODError.missingCredentials
        }
        let plain = try tokenVault.decrypt(stored, context: .broker)
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IBKRSODError.missingCredentials
        }
        return trimmed
    }
}
