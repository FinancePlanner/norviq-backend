import Fluent
import Vapor
import StockPlanShared

struct FeedbackController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let feedbacks = protected.grouped("feedback")
        feedbacks.post(use: submitFeedback)
    }

    @Sendable
    func submitFeedback(req: Request) async throws -> FeedbackResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(FeedbackRequest.self)
        let topic = payload.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !topic.isEmpty, topic.count <= 80 else {
            throw Abort(.badRequest, reason: "Feedback topic must be between 1 and 80 characters.")
        }

        guard !message.isEmpty, message.count <= 5_000 else {
            throw Abort(.badRequest, reason: "Feedback message must be between 1 and 5000 characters.")
        }

        let feedback = Feedback(
            topic: topic,
            message: message,
            userID: session.userId
        )

        try await feedback.save(on: req.db)

        return FeedbackResponse(success: true, message: "Feedback submitted successfully.")
    }
}
