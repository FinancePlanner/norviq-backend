import Foundation

/// The slice of Telegram's update payload this bot acts on.
struct TelegramUpdate: Decodable {
    struct Chat: Decodable {
        let id: Int64
        let type: String
    }

    /// A voice note or an audio file. Telegram sends a `file_id`, never bytes —
    /// the audio is fetched separately via `getFile`.
    struct Audio: Decodable {
        let fileID: String
        let duration: Int
        let mimeType: String?
        let fileSize: Int64?

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case mimeType = "mime_type"
            case fileSize = "file_size"
            case duration
        }
    }

    struct Message: Decodable {
        let messageId: Int64?
        let chat: Chat
        let text: String?
        let voice: Audio?
        let audio: Audio?

        enum CodingKeys: String, CodingKey {
            case messageId = "message_id"
            case chat, text, voice, audio
        }
    }

    struct CallbackQuery: Decodable {
        let id: String
        let data: String?
        let message: Message?
    }

    let updateId: Int64
    let message: Message?
    let callbackQuery: CallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

extension TelegramUpdate {
    /// What to do with this update.
    ///
    /// Anything unrecognised is ignored rather than guessed at — an update type
    /// we did not plan for should do nothing, not something arbitrary.
    /// Everything the bot needs to fetch and meter a voice note, without
    /// reaching back into the raw update.
    struct VoiceNote {
        let fileID: String
        let duration: Int
        let mimeType: String?
        let fileSize: Int64?
        let externalID: String
        let updateID: Int64
    }

    enum Intent {
        case answer(InboundMessage)
        /// Audio to transcribe, which then rejoins the text path.
        case voice(VoiceNote)
        /// The bot was added somewhere it must not be.
        case leave(chatID: String)
        case ignore
    }

    var intent: Intent {
        guard let source = callbackQuery?.message ?? message else { return .ignore }
        let chatID = String(source.chat.id)

        switch source.chat.type {
        case "private":
            break
        case "group", "supergroup", "channel":
            return .leave(chatID: chatID)
        default:
            return .ignore
        }

        // A button tap carries its payload in `data`; typed text in `text`.
        // Normalising both into `text` here keeps one path downstream.
        let text = (callbackQuery?.data ?? source.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            // No words, but possibly speech. `voice` is a recorded note; `audio`
            // is a forwarded file. Both transcribe the same way.
            if let clip = source.voice ?? source.audio {
                return .voice(VoiceNote(
                    fileID: clip.fileID,
                    duration: clip.duration,
                    mimeType: clip.mimeType,
                    fileSize: clip.fileSize,
                    externalID: chatID,
                    updateID: updateId
                ))
            }
            return .ignore
        }

        return .answer(InboundMessage(
            platform: MessagingPlatform.telegram,
            externalID: chatID,
            updateID: updateId,
            text: text,
            isPrivateChat: true,
            callbackQueryID: callbackQuery?.id
        ))
    }
}
