import Foundation
import NIOConcurrencyHelpers
import Vapor

/// In-flight turns, so they can be awaited when the application stops.
///
/// A turn runs detached from the delivery that started it, which means nothing
/// otherwise keeps it inside the application's lifetime. On a pod receiving
/// SIGTERM — or a test tearing its app down — a detached turn would go on using
/// a database and an event loop that are being dismantled underneath it, which
/// is a segfault rather than an error.
final class TelegramInFlightTurns: @unchecked Sendable {
    // NIOLock rather than NSLock: NSLock's lock() is unavailable from an
    // async context, and drain() is async.
    private let lock = NIOLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    /// Registers a task, or declines if shutdown has already begun.
    func register(_ id: UUID, task: Task<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return false }
        tasks[id] = task
        return true
    }

    func finish(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    var acceptsWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isShuttingDown
    }

    /// Stops accepting new turns and waits for the running ones.
    func drain() async {
        lock.lock()
        isShuttingDown = true
        let running = Array(tasks.values)
        lock.unlock()
        for task in running {
            task.cancel()
            await task.value
        }
    }
}

extension Application {
    private struct TelegramInFlightKey: StorageKey {
        typealias Value = TelegramInFlightTurns
    }

    var telegramInFlightTurns: TelegramInFlightTurns {
        if let existing = storage[TelegramInFlightKey.self] {
            return existing
        }
        let created = TelegramInFlightTurns()
        storage[TelegramInFlightKey.self] = created
        return created
    }
}

/// Awaits in-flight turns before the application tears itself down.
struct TelegramTurnDrain: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.telegramInFlightTurns.drain()
    }
}

/// Runs one update to completion, detached from whatever delivered it.
///
/// Both edges — webhook and poller — acknowledge before calling in here, so by
/// this point there is no inbound connection left to answer on. The `Request`
/// built below exists only to carry `Application` storage: every service a turn
/// touches (`db`, `userPIIEncryptionService`, `billingContextService`,
/// `client`, `logger`) reads through to the application, so a synthetic request
/// resolves them exactly as a real one does.
enum TelegramBridge {
    /// Above the assistant's own generation ceiling, so a slow turn ends by
    /// finishing rather than by timing out.
    static let replyTimeout: Duration = .seconds(360)
    /// Telegram clears the typing indicator after roughly five seconds.
    static let typingInterval: Duration = .seconds(4)

    static func dispatch(_ update: TelegramUpdate, application: Application) {
        guard let client = application.telegramConfiguration.map({ TelegramClient(token: $0.botToken) }) else { return }
        let turns = application.telegramInFlightTurns
        guard turns.acceptsWork else { return }
        let id = UUID()

        let task = Task {
            defer { turns.finish(id) }
            let req = Request(
                application: application,
                method: .POST,
                url: URI(string: "/internal/telegram-update"),
                on: application.eventLoopGroup.next()
            )
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await answer(update, client: client, req: req) }
                    group.addTask {
                        try await Task.sleep(for: replyTimeout)
                        throw TelegramClient.TelegramError.api("turn timed out")
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                req.logger.error("telegram_update_failed error=\(String(reflecting: type(of: error)))")
            }
        }

        // Lost the race against shutdown: stop before touching the application.
        if !turns.register(id, task: task) {
            task.cancel()
        }
    }

    private static func answer(_ update: TelegramUpdate, client: TelegramClient, req: Request) async throws {
        switch update.intent {
        case .ignore:
            return

        case let .leave(chatID):
            // Being added to a group is not an error, but it is not something
            // this bot can serve: one chat cannot map to one person's finances.
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: "I only work in a direct message, so I'll see myself out."),
                fallingBackSilently: req
            )
            await client.leave(chatID: chatID, req: req)

        case let .voice(note):
            try await transcribeAndAnswer(note, client: client, req: req)

        case let .answer(inbound):
            if let callbackID = inbound.callbackQueryID {
                await client.answerCallback(id: callbackID, req: req)
            }
            let typing = Task {
                while !Task.isCancelled {
                    await client.typing(chatID: inbound.externalID, req: req)
                    try? await Task.sleep(for: typingInterval)
                }
            }
            defer { typing.cancel() }

            let reply: OutboundMessage
            do {
                reply = try await MessagingService.handle(inbound, req: req)
            } catch {
                req.logger.error("messaging_handle_failed error=\(String(reflecting: type(of: error)))")
                // Silence would read as the bot being broken or ignoring them.
                reply = OutboundMessage(text: "Something went wrong on my side. Try again in a moment.")
            }
            typing.cancel()
            try await client.send(chatID: inbound.externalID, message: reply, req: req)
        }
    }
}

extension TelegramBridge {
    /// Picks the wording for a failed voice turn.
    ///
    /// Anything that is not a typed transcription failure — a download error,
    /// a decode error — is reported as a failure to hear, never as a billing
    /// problem the user cannot act on.
    static func transcriptionFailureMessage(for error: any Error) -> String {
        (error as? TranscriptionFailure ?? .failed).message
    }

    /// Shown before the answer so a misheard ticker reads as a mistake the user
    /// can correct, rather than arriving invisibly inside a confident answer
    /// about the wrong company.
    static func voiceEcho(_ transcript: String) -> String {
        "\u{1F3A4} \u{201C}\(transcript)\u{201D}"
    }

    /// Audio in, text out: transcribe, show the user what was heard, then hand
    /// the words to exactly the path a typed message takes.
    private static func transcribeAndAnswer(
        _ note: TelegramUpdate.VoiceNote,
        client: TelegramClient,
        req: Request
    ) async throws {
        let chatID = note.externalID

        let provider = req.application.transcriptionProvider
        guard provider.isEnabled else {
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: "I can't listen to voice notes yet. Type it and I'll answer."),
                fallingBackSilently: req
            )
            return
        }

        let limits = req.application.transcriptionLimits
        // Checked before the download, not after: the update already carries
        // duration and size, and this pod holds the audio in memory.
        if let rejection = limits.rejection(duration: note.duration, fileSize: note.fileSize) {
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: rejection.message),
                fallingBackSilently: req
            )
            return
        }

        // An unlinked chat must not be able to spend the transcription budget.
        guard let link = try await MessagingService.linkedUser(
            platform: MessagingPlatform.telegram, externalID: chatID, req: req
        ) else {
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: MessagingService.connectInstructions),
                fallingBackSilently: req
            )
            return
        }

        let typing = Task {
            while !Task.isCancelled {
                await client.typing(chatID: chatID, req: req)
                try? await Task.sleep(for: typingInterval)
            }
        }
        defer { typing.cancel() }

        do {
            try await VoiceDailyCap.charge(req, userId: link.userId, seconds: note.duration)
        } catch let abort as any AbortError {
            typing.cancel()
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: abort.reason),
                fallingBackSilently: req
            )
            return
        }

        let transcript: String
        do {
            let file = try await client.getFile(fileID: note.fileID, req: req)
            // getFile reports the real size; the update's was advisory.
            if let rejection = limits.rejection(duration: note.duration, fileSize: file.fileSize) {
                typing.cancel()
                await client.send(
                    chatID: chatID,
                    message: OutboundMessage(text: rejection.message),
                    fallingBackSilently: req
                )
                return
            }
            let audio = try await client.downloadFile(path: file.filePath, req: req)
            let hint = await TranscriptionHint.forUser(link.userId, req: req)
            transcript = try await provider.transcribe(
                audio: audio, mimeType: note.mimeType, hint: hint, on: req
            )
        } catch {
            typing.cancel()
            req.logger.error("telegram_transcription_failed error=\(String(reflecting: type(of: error)))")
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: transcriptionFailureMessage(for: error)),
                fallingBackSilently: req
            )
            return
        }

        guard !transcript.isEmpty else {
            typing.cancel()
            await client.send(
                chatID: chatID,
                message: OutboundMessage(text: "I couldn't make out any words in that. Try again, or type it."),
                fallingBackSilently: req
            )
            return
        }

        await client.send(
            chatID: chatID,
            message: OutboundMessage(text: voiceEcho(transcript)),
            fallingBackSilently: req
        )

        // From here the audio no longer exists as far as the bot is concerned:
        // this is the same InboundMessage a typed message would have produced.
        let inbound = InboundMessage(
            platform: MessagingPlatform.telegram,
            externalID: chatID,
            updateID: note.updateID,
            text: transcript,
            isPrivateChat: true,
            callbackQueryID: nil
        )

        let reply: OutboundMessage
        do {
            reply = try await MessagingService.handle(inbound, req: req)
        } catch {
            req.logger.error("messaging_handle_failed error=\(String(reflecting: type(of: error)))")
            reply = OutboundMessage(text: "Something went wrong on my side. Try again in a moment.")
        }
        typing.cancel()
        try await client.send(chatID: chatID, message: reply, req: req)
    }
}

private extension TelegramClient {
    /// For courtesy messages where a delivery failure should not abort the
    /// larger action that follows it.
    func send(chatID: String, message: OutboundMessage, fallingBackSilently req: Request) async {
        try? await send(chatID: chatID, message: message, req: req)
    }
}
