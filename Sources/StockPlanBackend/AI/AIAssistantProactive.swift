import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Messages the assistant posts into a thread on its own, and the standing
/// tasks that produce some of them.
///
/// Delivery is always the same two steps (contract "Proactive messages"):
/// append to the thread with `origin: proactive` and a caption, then push a
/// notification that deep-links to that thread.
enum AIAssistantProactive {
    /// `AIPendingAction.toolName` for a proposed standing task. Not an
    /// `ActionCatalog` action: the coordinator's confirm handles it directly.
    static let createWatchToolName = "create_watch"
    static let standingTaskLabel = "Standing task"
    static let dailyTipLabel = "Daily tip"
    /// A conditional watch answers exactly this when there is nothing to say.
    static let noUpdateToken = "NO_UPDATE"

    /// What a `create_watch` pending action stores in `arguments`. Clients may
    /// read `title`, `scheduleHuman`, `intervalMinutes` and `spec` from it to
    /// redraw the card after a reload (`GET /v1/ai/assistant/actions`).
    struct WatchArguments: Codable, Equatable {
        let title: String
        let scheduleHuman: String
        let intervalMinutes: Int
        let spec: String
        let subject: String
        let condition: String?
        let confirmationText: String
        let firstRunAt: Date

        init(intent: AIWatchIntentClassifier.Intent, firstRunAt: Date) {
            title = intent.title
            scheduleHuman = intent.scheduleHuman
            intervalMinutes = intent.intervalMinutes
            spec = intent.spec
            subject = intent.subject
            condition = intent.condition
            confirmationText = intent.confirmationText
            self.firstRunAt = firstRunAt
        }

        var proposal: AIWatchProposalResponse {
            AIWatchProposalResponse(title: title, scheduleHuman: scheduleHuman, intervalMinutes: intervalMinutes, spec: spec)
        }

        func encoded() throws -> String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try String(decoding: encoder.encode(self), as: UTF8.self)
        }

        static func decode(_ json: String) throws -> WatchArguments {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WatchArguments.self, from: Data(json.utf8))
        }
    }

    // MARK: - Append + push

    /// Appends a proactive assistant message and keeps the thread alive.
    @discardableResult
    static func append(
        text: String,
        sourceLabel: String,
        userId: UUID,
        conversation: AIConversation,
        app: Application
    ) async throws -> AIAssistantMessage {
        let message = try AIAssistantMessage(
            conversationId: conversation.requireID(),
            userId: userId,
            role: AIAssistantRole.assistant.rawValue,
            contentEncrypted: app.userPIIEncryptionService.encryptString(text),
            origin: AIMessageOrigin.proactive.rawValue,
            sourceLabel: sourceLabel
        )
        conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
        try await app.db.transaction { database in
            try await message.create(on: database)
            try await conversation.save(on: database)
        }
        return message
    }

    /// Pushes a proactive message to every active device of the user.
    @discardableResult
    static func push(
        message: AIAssistantMessage,
        title: String,
        body: String,
        userId: UUID,
        req: Request
    ) async -> TargetPushSendSummary {
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: userId, on: req.db)
            let push = try AssistantPushMessage(
                conversationId: message.$conversation.id,
                messageId: message.requireID(),
                sourceLabel: message.sourceLabel ?? standingTaskLabel,
                title: String(title.prefix(80)),
                body: String(body.prefix(180))
            )
            return await req.application.pushNotificationSender.sendAssistantMessage(
                message: push, devices: devices, req: req
            )
        } catch {
            req.logger.warning("ai_assistant.proactive_push_failed error=\(error)")
            return .init(delivered: 0, failed: 0)
        }
    }

    /// The thread a proactive message without its own thread lands in: the
    /// most recently active, unexpired one.
    static func latestConversation(userId: UUID, on database: any Database) async throws -> AIConversation? {
        try await AIConversation.query(on: database)
            .filter(\.$userId == userId)
            .filter(\.$expiresAt > Date())
            .sort(\.$updatedAt, .descending)
            .first()
    }

    // MARK: - Daily tip

    /// Posts a generated daily tip into the user's latest thread and pushes it
    /// when the user turned assistant pushes on. Returns the message, or nil
    /// when the user has no thread to post into.
    @discardableResult
    static func deliverDailyTip(
        title: String,
        body: String,
        userId: UUID,
        app: Application
    ) async throws -> AIAssistantMessage? {
        guard let conversation = try await latestConversation(userId: userId, on: app.db) else { return nil }
        let message = try await append(
            text: "**\(title)**\n\n\(body)",
            sourceLabel: dailyTipLabel,
            userId: userId,
            conversation: conversation,
            app: app
        )
        let pushEnabled = try await AIAssistantPreference.query(on: app.db)
            .filter(\.$userId == userId).first()?.pushEnabled ?? false
        if pushEnabled {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            await push(message: message, title: title, body: body, userId: userId, req: req)
        }
        return message
    }

    // MARK: - Standing tasks

    /// Persists a `create_watch` proposal for the user to confirm or cancel.
    static func proposeWatch(
        intent: AIWatchIntentClassifier.Intent,
        userId: UUID,
        conversationId: UUID,
        req: Request
    ) async throws -> (action: AIPendingAction, arguments: WatchArguments) {
        let timezone = try await AIAssistantPreference.query(on: req.db)
            .filter(\.$userId == userId).first()
            .flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone(identifier: "UTC")!
        let arguments = WatchArguments(intent: intent, firstRunAt: intent.firstRunAt(after: Date(), timeZone: timezone))
        let action = AIPendingAction()
        action.userId = userId
        action.conversationId = conversationId
        action.toolName = createWatchToolName
        action.argumentsEncrypted = try req.userPIIEncryptionService.encryptString(arguments.encoded())
        action.summaryEncrypted = try req.userPIIEncryptionService.encryptString(intent.summary)
        action.status = AIActionStatus.pending.rawValue
        // A card the user can come back to later the same day, unlike a
        // destructive-write proposal.
        action.expiresAt = Date().addingTimeInterval(24 * 3600)
        try await action.create(on: req.db)
        return (action, arguments)
    }

    static func proposalText(_ intent: AIWatchIntentClassifier.Intent) -> String {
        "I can set that up as a standing task: \(intent.title) — \(AIWatchIntentClassifier.lowercasedFirst(intent.scheduleHuman)). Confirm and I'll take it from there."
    }

    /// Creates the watch a confirmed `create_watch` action describes and posts
    /// the "Got it" message into its thread.
    static func createWatch(
        from action: AIPendingAction,
        arguments json: String,
        userId: UUID,
        req: Request
    ) async throws -> AIConfirmedActionExecutor.Result {
        let arguments = try WatchArguments.decode(json)
        guard let conversationId = action.conversationId,
              let conversation = try await AIConversation.query(on: req.db)
              .filter(\.$id == conversationId).filter(\.$userId == userId).first()
        else { throw Abort(.unprocessableEntity, reason: "That conversation no longer exists.") }

        let crypto = req.userPIIEncryptionService
        let watch = AIAssistantWatch()
        watch.userId = userId
        watch.conversationId = conversationId
        watch.titleEncrypted = try crypto.encryptString(arguments.title)
        watch.specEncrypted = try crypto.encryptString(arguments.spec)
        watch.conditionEncrypted = try arguments.condition.map { try crypto.encryptString($0) }
        watch.scheduleHuman = arguments.scheduleHuman
        watch.intervalMinutes = max(AIWatchIntentClassifier.minimumIntervalMinutes, arguments.intervalMinutes)
        // A proposal confirmed after its anchor passed runs at the next one.
        var next = arguments.firstRunAt
        let now = Date()
        while next <= now {
            next = next.addingTimeInterval(TimeInterval(watch.intervalMinutes * 60))
        }
        watch.nextRunAt = next
        watch.enabled = true
        try await watch.create(on: req.db)

        try await append(
            text: arguments.confirmationText,
            sourceLabel: standingTaskLabel,
            userId: userId,
            conversation: conversation,
            app: req.application
        )
        return try .init(id: watch.requireID(), message: arguments.confirmationText)
    }

    /// The question a watch asks the model on each run.
    static func runPrompt(spec: String, condition: String?, scheduleHuman: String) -> String {
        if let condition {
            return """
            Standing task check. This runs automatically; the user is not waiting for a reply.
            The user asked: "\(spec)"
            Check now with your read tools. If "\(condition)" is true right now, reply with one or two short sentences telling the user, including the numbers you found.
            If it is not true, or you cannot tell from the data, reply with exactly \(noUpdateToken) and nothing else.
            """
        }
        return """
        Standing task (\(scheduleHuman)). This runs automatically; the user is not waiting for a reply.
        The user asked: "\(spec)"
        Do it now with your read tools and reply with a short update addressed to the user. Do not ask questions and do not offer to make changes.
        """
    }
}
