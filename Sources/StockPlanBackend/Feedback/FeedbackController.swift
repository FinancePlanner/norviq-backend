import Fluent
import Vapor
import StockPlanShared

struct FeedbackController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let feedbacks = protected.grouped("feedback")
        feedbacks.post(use: submitFeedback)
    }

    @Sendable
    func submitFeedback(req: Request) async throws -> FeedbackResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(FeedbackRequest.self)
        
        let feedback = Feedback(
            topic: payload.topic,
            message: payload.message,
            userID: session.userId
        )
        
        try await feedback.save(on: req.db)
        
        return FeedbackResponse(success: true, message: "Feedback submitted successfully.")
    }
}
