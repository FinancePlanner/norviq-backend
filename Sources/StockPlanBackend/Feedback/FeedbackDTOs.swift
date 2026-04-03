import Vapor

struct FeedbackRequest: Content {
    let topic: String
    let message: String
}

struct FeedbackResponse: Content {
    let success: Bool
    let message: String?
}
