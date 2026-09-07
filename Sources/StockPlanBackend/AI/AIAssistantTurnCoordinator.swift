import Fluent
import Foundation
import StockPlanShared
import Vapor

/// One assistant turn, independent of how the request arrived.
///
/// The HTTP route used to own this whole sequence, which meant the assistant
/// could only be reached by something holding a `SessionToken`. Telegram
/// updates carry no such token — they carry a chat id that a `MessagingLink`
/// resolves to a user. Minting a synthetic session for that chat would hand a
/// messaging bridge a real bearer credential with every scope the app has, to
/// obtain a `UUID` it already knows. So the orchestration lives here and takes
/// the user id directly; `AIAssistantController.chat` and the Telegram bridge
/// are both thin callers.
///
/// Everything a turn touches — encryption, billing, the model client — hangs off
/// `Application` storage rather than the request, so `req` here may be a
/// synthetic `Request` detached from any inbound connection.
enum AIAssistantTurnCoordinator {
    /// A completed turn, including the persisted assistant message so HTTP
    /// callers can build a DTO with its real id and timestamp.
    struct Outcome {
        let text: String
        let pendingAction: AIPendingAction?
        let assistantMessage: AIAssistantMessage
    }

    static let maxMessageCharacters = 12000

    static func run(
        userId: UUID,
        conversation: AIConversation,
        content: String,
        req: Request
    ) async throws -> Outcome {
        let conversationId = try conversation.requireID()
        guard !content.isEmpty, content.count <= maxMessageCharacters else {
            throw Abort(.badRequest, reason: "Message must contain 1 to 12,000 characters.")
        }
        // Resolved before the quota check on purpose: a user paying for their
        // own inference must not also spend a Norviq turn from the free-tier
        // cap. The global kill switch and the route rate limit still apply.
        let resolved = try await AIAssistantClientResolver.resolve(userId: userId, on: req)
        if !resolved.usesOwnKey {
            try await consumeAssistantTurn(userId: userId, req: req)
        }
        let userMessage = try AIAssistantMessage(
            conversationId: conversationId,
            userId: userId,
            role: AIAssistantRole.user.rawValue,
            contentEncrypted: req.userPIIEncryptionService.encryptString(content)
        )
        try await userMessage.create(on: req.db)

        let result = try await runTurn(
            resolved: resolved,
            userId: userId,
            conversation: conversation,
            content: content,
            mode: confirmationMode(for: req),
            req: req
        )
        let assistantMessage = try AIAssistantMessage(
            conversationId: conversationId,
            userId: userId,
            role: AIAssistantRole.assistant.rawValue,
            contentEncrypted: req.userPIIEncryptionService.encryptString(result.text)
        )
        conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
        try await req.db.transaction { database in
            try await assistantMessage.create(on: database)
            try await conversation.save(on: database)
        }
        return Outcome(text: result.text, pendingAction: result.pendingAction, assistantMessage: assistantMessage)
    }

    /// How this caller must prove the user consented to a destructive action.
    ///
    /// A first-party session — the app, and Telegram, whose synthetic `Request`
    /// carries no auth at all because a `MessagingLink` is itself proof of
    /// account ownership — gets `.destructiveOnly`: harmless writes apply as the
    /// user asked, deletions still need a tap.
    ///
    /// A scoped bearer token gets `.everyWrite`. `POST .../chat` only requires
    /// `assistant:write`, so without this a token holding nothing else would
    /// silently gain `expenses:write`, `stocks:write`, watchlist and transaction
    /// writes the moment writes started applying inline. Under `.everyWrite` it
    /// can still only *propose*, and completing a proposal requires the
    /// first-party-only confirm route — so its blast radius is exactly what it
    /// was before the catalog reached this surface.
    static func confirmationMode(for req: Request) -> ActionConfirmationMode {
        req.auth.get(ScopeContext.self) == nil
            ? .deferred(requiring: .destructiveOnly)
            : .deferred(requiring: .everyWrite)
    }

    /// Executes a pending action the user has explicitly approved.
    ///
    /// Runs in three phases — claim, execute, settle — rather than one
    /// transaction.
    ///
    /// **Claim** re-checks status and expiry and flips the row to `confirmed`
    /// inside a transaction. That is the replay guard, and the only atomicity
    /// that actually matters here: a Telegram button tapped twice finds a row
    /// that is no longer `pending` and gets the 409 the bridge already renders.
    ///
    /// **Execute** then runs outside any transaction, because the action catalog
    /// reaches its services through `Request` and Fluent's `any Database` is not
    /// `Sendable`, so a transaction handle cannot be threaded into a `@Sendable`
    /// handler under Swift 6 strict concurrency.
    ///
    /// This deliberately gives up committing the domain write and its audit row
    /// together. That guarantee was already illusory for anything touching more
    /// than one service — `sell_position` credits cash *and* records a trade —
    /// and the audit row is written before the attempt and settled after it, so
    /// a crash mid-execute leaves an `executing` row rather than no trace.
    static func confirm(
        actionId: UUID,
        userId: UUID,
        req: Request
    ) async throws -> AIConfirmedActionExecutor.Result {
        // Claim.
        let claim = try await req.db.transaction { database -> (action: AIPendingAction, audit: AIActionAudit) in
            guard let action = try await AIPendingAction.query(on: database)
                .filter(\.$id == actionId).filter(\.$userId == userId).first()
            else { throw Abort(.notFound) }
            guard action.status == AIActionStatus.pending.rawValue, action.expiresAt > Date() else {
                throw Abort(.conflict, reason: "Action is no longer available for confirmation.")
            }
            let audit = AIActionAudit()
            audit.userId = userId; audit.pendingActionId = actionId; audit.toolName = action.toolName; audit.status = "executing"
            try await audit.create(on: database)
            action.status = AIActionStatus.confirmed.rawValue
            try await action.save(on: database)
            return (action, audit)
        }

        let argumentsText = try req.userPIIEncryptionService.decryptString(claim.action.argumentsEncrypted)
        guard let arguments = argumentsText.data(using: .utf8) else { throw Abort(.badRequest) }

        // Execute.
        let executed: AIConfirmedActionExecutor.Result
        do {
            executed = try await AIConfirmedActionExecutor().execute(
                toolName: claim.action.toolName,
                arguments: arguments,
                userId: userId,
                on: req
            )
        } catch {
            // Settle as failed, then surface the original reason — the caller
            // renders it as a sentence to the user.
            try? await req.db.transaction { database in
                claim.action.status = AIActionStatus.failed.rawValue
                claim.audit.status = AIActionStatus.failed.rawValue
                try await claim.action.save(on: database)
                try await claim.audit.save(on: database)
            }
            throw error
        }

        // Settle.
        try await req.db.transaction { database in
            claim.action.status = AIActionStatus.completed.rawValue
            claim.audit.status = AIActionStatus.completed.rawValue
            try await claim.action.save(on: database)
            try await claim.audit.save(on: database)
        }
        return executed
    }

    /// Runs one turn with whichever client the resolver picked.
    ///
    /// On a user's own key, an upstream auth failure is translated into a typed
    /// `AIUserCredentialFailure` and recorded on the credential, so the settings
    /// page can show "key rejected" without the user having to hit Test. When
    /// running on Norviq's key the error passes through untouched.
    static func runTurn(
        resolved: ResolvedAssistantClient,
        userId: UUID,
        conversation: AIConversation,
        content: String,
        mode: ActionConfirmationMode = .deferred(requiring: .destructiveOnly),
        req: Request
    ) async throws -> AIAssistantTurnService.Result {
        // The kill switch normally runs inside consumeAssistantTurn, which a
        // BYO turn skips — so apply it here too. Bringing your own key does not
        // opt you out of Norviq's own controls.
        if resolved.usesOwnKey {
            try AICostControls.requireEnabled(reason: "The assistant is temporarily unavailable.")
        }

        do {
            let result = try await AIAssistantTurnService(client: resolved.client)
                .generate(userId: userId, conversation: conversation, userMessage: content, mode: mode, req: req)
            if let credential = resolved.credential {
                await AIAssistantClientResolver.recordSuccess(credential, on: req)
            }
            return result
        } catch let upstream as OpenAIChatUpstreamError {
            guard let credential = resolved.credential, let id = credential.id else { throw upstream }

            let failure: AIUserCredentialFailure = if upstream.isAuthFailure {
                .rejected(provider: credential.provider, credentialId: id)
            } else if upstream.isRateLimit {
                .rateLimited(provider: credential.provider, credentialId: id)
            } else {
                .unreachable(provider: credential.provider, credentialId: id)
            }
            await AIAssistantClientResolver.recordFailure(credential, failure: failure, on: req)

            // Falling back would quietly move the bill to Norviq and hide a
            // credential the user asked us to use, so it is off by default.
            if AICredentialSettings.fallbackToNorviqKey {
                req.logger.warning("ai_credential_fallback provider=\(credential.provider)")
                // Plan-routed: moving the bill to Norviq is bad enough without
                // also moving a free user onto the paid chain.
                let routed = await AIPlanRouting.client(for: userId, on: req)
                return try await AIAssistantTurnService(client: routed.client)
                    .generate(userId: userId, conversation: conversation, userMessage: content, mode: mode, req: req)
            }
            // 424 reads exactly right: your upstream dependency failed, not ours.
            throw Abort(.failedDependency, reason: failure.userFacingMessage)
        }
    }

    /// Spends one turn from the user's monthly allowance.
    ///
    /// Every entry point shares this counter. A linked Telegram chat must never
    /// be a cheaper door to the model than the app is.
    static func consumeAssistantTurn(userId: UUID, req: Request) async throws {
        try AICostControls.requireEnabled(reason: "The assistant is temporarily unavailable.")
        let billing = try await req.application.billingContextService.context(userId: userId, on: req.db)
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let freeLimit = AICostControls.freeMonthlyLimit
        try await req.db.transaction { database in
            let usage = try await AIAssistantUsage.query(on: database).filter(\.$userId == userId)
                .filter(\.$monthStart == month).first() ?? AIAssistantUsage(userId: userId, monthStart: month)
            guard billing.isPro || usage.requestCount < freeLimit else {
                throw Abort(
                    .paymentRequired,
                    reason: "The free AI preview includes \(freeLimit) requests per month."
                )
            }
            usage.requestCount += 1; try await usage.save(on: database)
        }
    }
}
