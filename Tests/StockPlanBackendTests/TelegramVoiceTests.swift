import Foundation
@testable import StockPlanBackend
import Testing

/// Pure decoding and policy — no database, no network.
///
/// Before voice support the bot decoded only `text`, so a voice note parsed
/// into a `Message` with `text == nil` and `intent` returned `.ignore`: the
/// user got silence. These tests guard that path.
@Suite("Telegram voice updates")
struct TelegramVoiceUpdateTests {
    private func update(from json: String) throws -> TelegramUpdate {
        try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    }

    @Test("A voice note becomes a transcribable intent, not silence")
    func voiceNote() throws {
        let parsed = try update(from: #"""
        {"update_id":11,"message":{"message_id":3,"chat":{"id":4242,"type":"private"},
        "voice":{"file_id":"AwACAgQAAx","duration":7,"mime_type":"audio/ogg","file_size":12345}}}
        """#)
        guard case let .voice(note) = parsed.intent else {
            Issue.record("expected a voice intent"); return
        }
        #expect(note.fileID == "AwACAgQAAx")
        #expect(note.duration == 7)
        #expect(note.mimeType == "audio/ogg")
        #expect(note.fileSize == 12345)
        #expect(note.externalID == "4242")
        #expect(note.updateID == 11)
    }

    @Test("A voice note in a group still makes the bot leave")
    func voiceInGroup() throws {
        let parsed = try update(from: #"""
        {"update_id":12,"message":{"message_id":3,"chat":{"id":-100200,"type":"supergroup"},
        "voice":{"file_id":"x","duration":2}}}
        """#)
        guard case let .leave(chatID) = parsed.intent else {
            Issue.record("expected a leave intent"); return
        }
        #expect(chatID == "-100200")
    }

    @Test("Text still wins when a message somehow carries both")
    func captionedVoicePrefersText() throws {
        let parsed = try update(from: #"""
        {"update_id":13,"message":{"message_id":3,"chat":{"id":9,"type":"private"},
        "text":"typed","voice":{"file_id":"x","duration":2}}}
        """#)
        guard case let .answer(inbound) = parsed.intent else {
            Issue.record("expected an answerable intent"); return
        }
        #expect(inbound.text == "typed")
    }

    @Test("A forwarded audio file is transcribed like a voice note")
    func audioFile() throws {
        let parsed = try update(from: #"""
        {"update_id":14,"message":{"message_id":3,"chat":{"id":9,"type":"private"},
        "audio":{"file_id":"aud1","duration":30,"mime_type":"audio/mpeg","file_size":500}}}
        """#)
        guard case let .voice(note) = parsed.intent else {
            Issue.record("expected a voice intent"); return
        }
        #expect(note.fileID == "aud1")
        #expect(note.duration == 30)
    }

    @Test("An update with neither text nor audio is still ignored")
    func stillIgnoresEmpty() throws {
        let parsed = try update(from: #"{"update_id":15,"message":{"message_id":3,"chat":{"id":9,"type":"private"}}}"#)
        guard case .ignore = parsed.intent else {
            Issue.record("expected ignore"); return
        }
    }
}

/// The guard exists for one reason: the API pod runs under a 450Mi limit and
/// holds audio in memory. Telegram tells us duration and size *in the update*,
/// so an oversized clip is refused before a single byte is downloaded.
@Suite("Transcription limits")
struct TranscriptionLimitsTests {
    private let eightMB: Int64 = 8 * 1024 * 1024
    private var limits: TranscriptionLimits {
        TranscriptionLimits(maxSeconds: 300, maxBytes: eightMB)
    }

    @Test("An ordinary voice note is accepted")
    func acceptsNormalClip() {
        #expect(limits.rejection(duration: 30, fileSize: 120_000) == nil)
    }

    @Test("A clip over the duration limit is refused")
    func refusesLongClip() {
        #expect(limits.rejection(duration: 301, fileSize: 1000) == .tooLong(maxSeconds: 300))
    }

    @Test("A clip over the byte limit is refused")
    func refusesLargeClip() {
        let nineMB: Int64 = 9 * 1024 * 1024
        #expect(limits.rejection(duration: 10, fileSize: nineMB) == .tooLarge(maxBytes: eightMB))
    }

    @Test("A missing file size is not treated as zero")
    func toleratesUnknownSize() {
        // Telegram may omit file_size. Duration still guards us, and the
        // download itself is capped separately.
        #expect(limits.rejection(duration: 10, fileSize: Int64?.none) == nil)
    }

    @Test("Exactly at the limit is allowed, not refused")
    func boundariesAreInclusive() {
        #expect(limits.rejection(duration: 300, fileSize: eightMB) == nil)
    }

    @Test("Every rejection explains itself to the user")
    func rejectionsAreUserFacing() {
        #expect(TranscriptionRejection.tooLong(maxSeconds: 300).message.contains("5 minutes"))
        #expect(!TranscriptionRejection.tooLarge(maxBytes: 8 * 1024 * 1024).message.isEmpty)
    }
}

/// Telegram hands out a `file_id`, never bytes. Fetching audio is therefore two
/// steps — `getFile` for a path, then a plain GET on a *different* host prefix.
@Suite("Telegram file fetching")
struct TelegramFileFetchTests {
    private let client = TelegramClient(token: "123:SECRET", baseURL: "https://api.telegram.org")

    @Test("The download URL uses the file prefix, not the bot method prefix")
    func buildsDownloadURL() {
        #expect(client.fileDownloadURL(path: "voice/file_1.oga")
            == "https://api.telegram.org/file/bot123:SECRET/voice/file_1.oga")
    }

    @Test("A getFile response yields the path to download")
    func decodesFilePath() throws {
        let json = #"{"ok":true,"result":{"file_id":"x","file_path":"voice/file_1.oga","file_size":9001}}"#
        let file = try TelegramClient.decodeFile(from: Data(json.utf8))
        #expect(file.filePath == "voice/file_1.oga")
        #expect(file.fileSize == 9001)
    }

    @Test("A failed getFile is an error, not a silent empty path")
    func rejectsFailedLookup() {
        #expect(throws: (any Error).self) {
            try TelegramClient.decodeFile(from: Data(#"{"ok":false,"description":"file is too big"}"#.utf8))
        }
    }

    @Test("A file with no path is refused rather than downloaded from nowhere")
    func rejectsMissingPath() {
        #expect(throws: (any Error).self) {
            try TelegramClient.decodeFile(from: Data(#"{"ok":true,"result":{"file_id":"x"}}"#.utf8))
        }
    }
}

/// The echo is the feature's only quality signal. Without it a misheard ticker
/// arrives invisibly, inside a confident answer about the wrong company.
@Suite("Voice transcript echo")
struct VoiceEchoTests {
    @Test("The transcript is quoted back before the answer")
    func quotesTranscript() {
        let echo = TelegramBridge.voiceEcho("how is NVDA doing")
        #expect(echo.contains("how is NVDA doing"))
    }

    @Test("The echo is visibly a quote, not mistakable for the answer")
    func readsAsAQuote() {
        let echo = TelegramBridge.voiceEcho("hello")
        #expect(echo != "hello")
        #expect(echo.first == "\u{1F3A4}")
    }

    @Test("Markup in a transcript stays text, never formatting")
    func doesNotInjectMarkup() {
        // TelegramFormat escapes on send, but the echo must not add markup of
        // its own that a transcript could then close.
        let echo = TelegramBridge.voiceEcho("<b>buy</b> everything")
        #expect(echo.contains("<b>buy</b> everything"))
    }
}
