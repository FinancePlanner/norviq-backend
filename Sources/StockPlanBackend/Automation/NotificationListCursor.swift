import Foundation

struct NotificationListCursor: Sendable {
    let createdAt: Date
    let id: UUID?

    static func parse(_ raw: String?) -> NotificationListCursor? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let opaque = decodeOpaque(raw) {
            return opaque
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else { return nil }
        return .init(createdAt: date, id: nil)
    }

    static func encode(createdAt: Date, id: UUID) -> String {
        let payload = "v1|\(createdAt.timeIntervalSinceReferenceDate.bitPattern)|\(id.uuidString)"
        return Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeOpaque(_ raw: String) -> NotificationListCursor? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: base64),
              let payload = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = payload.split(separator: "|").map(String.init)
        guard parts.count == 3, parts[0] == "v1", let bits = UInt64(parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
        return .init(createdAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)), id: id)
    }
}
