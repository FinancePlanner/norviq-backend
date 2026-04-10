import Foundation
import Vapor

struct APNSBootstrapConfiguration: Sendable {
    let teamID: String
    let keyID: String
    let privateKeyP8: String
    let topic: String

    static func fromEnvironment(app: Application) -> APNSBootstrapConfiguration? {
        let teamID = Environment.get("APNS_TEAM_ID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keyID = Environment.get("APNS_KEY_ID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topic = Environment.get("APNS_TOPIC")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let privateKeyRaw = Environment.get("APNS_PRIVATE_KEY_P8")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let normalizedPrivateKey = privateKeyRaw.replacingOccurrences(of: "\\n", with: "\n")

        let hasAllValues = !teamID.isEmpty && !keyID.isEmpty && !topic.isEmpty && !normalizedPrivateKey.isEmpty
        guard hasAllValues else {
            app.logger.warning(
                "APNS is disabled. Configure APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY_P8 and APNS_TOPIC to enable push notifications."
            )
            return nil
        }

        return .init(
            teamID: teamID,
            keyID: keyID,
            privateKeyP8: normalizedPrivateKey,
            topic: topic
        )
    }
}
