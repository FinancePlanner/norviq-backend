import Foundation
import Vapor

/// Why transcription did not produce text.
///
/// Split out because these read very differently to a user: telling someone
/// their audio was unclear when the account is actually out of credit sends
/// them back to re-record a clip that can never work.
enum TranscriptionFailure: Error, Equatable {
    /// Out of credit, or the key is rejected. The feature is off, not fussy.
    case unavailable
    /// Rate limited. Worth another go shortly.
    case busy
    /// A genuine failure to turn this audio into words.
    case failed

    static func from(status: UInt) -> TranscriptionFailure {
        switch status {
        case 401, 402, 403: .unavailable
        case 429: .busy
        default: .failed
        }
    }

    var message: String {
        switch self {
        case .unavailable:
            "Voice is switched off at the moment. Type it and I'll answer the same way."
        case .busy:
            "I'm behind on voice notes right now. Try that again in a moment, or type it."
        case .failed:
            "I couldn't make that out. Try again, or type it."
        }
    }
}
