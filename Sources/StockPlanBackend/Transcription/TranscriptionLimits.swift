import Foundation
import Vapor

/// Why a clip was refused, and what to say about it.
enum TranscriptionRejection: Equatable, Sendable {
    case tooLong(maxSeconds: Int)
    case tooLarge(maxBytes: Int64)

    var message: String {
        switch self {
        case let .tooLong(maxSeconds):
            let minutes = maxSeconds / 60
            let limit = minutes >= 1 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(maxSeconds) seconds"
            return "That voice note is longer than \(limit). Send a shorter one, or type it."
        case let .tooLarge(maxBytes):
            let megabytes = Double(maxBytes) / (1024 * 1024)
            return "That audio file is bigger than \(String(format: "%.0f", megabytes))MB. Send a shorter one, or type it."
        }
    }
}

/// Caps on what the bot will download and transcribe.
///
/// These are refused *before* the download, not after: Telegram puts duration
/// and size in the update itself, and the API pod holds audio in memory under a
/// 450Mi limit. Checking first is what keeps a long clip from becoming an OOM.
struct TranscriptionLimits: Sendable {
    let maxSeconds: Int
    let maxBytes: Int64

    static let `default` = TranscriptionLimits(maxSeconds: 300, maxBytes: 8 * 1024 * 1024)

    static func fromEnvironment() -> TranscriptionLimits {
        TranscriptionLimits(
            maxSeconds: Environment.get("TRANSCRIBE_MAX_SECONDS").flatMap(Int.init) ?? `default`.maxSeconds,
            maxBytes: Environment.get("TRANSCRIBE_MAX_BYTES").flatMap(Int64.init) ?? `default`.maxBytes
        )
    }

    /// `nil` means the clip is acceptable. A missing `fileSize` is unknown, not
    /// zero — duration still guards, and the download is capped separately.
    func rejection(duration: Int, fileSize: Int64?) -> TranscriptionRejection? {
        if duration > maxSeconds {
            return .tooLong(maxSeconds: maxSeconds)
        }
        if let fileSize, fileSize > maxBytes {
            return .tooLarge(maxBytes: maxBytes)
        }
        return nil
    }
}
