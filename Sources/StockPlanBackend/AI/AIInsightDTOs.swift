import Foundation
import Vapor

// NOTE: These response DTOs currently live in the backend so the feature branch
// builds and tests standalone without a cross-repo push. Before iOS integration,
// promote this file into the shared `StockPlanShared` (FinanceShared) package so the
// client and server share one contract — same pattern as CryptoDTOs.swift.

/// Which insight card the client is asking for.
public enum AIInsightKind: String, Content, Sendable {
    case expenses
    case portfolio
    case summary
}

/// A single labelled metric surfaced on an insight card.
public struct AIInsightHighlight: Content, Sendable {
    public var label: String
    public var value: String
    /// Optional direction indicator: "up", "down", or "flat".
    public var trend: String?

    public init(label: String, value: String, trend: String? = nil) {
        self.label = label
        self.value = value
        self.trend = trend
    }
}

/// An educational, plain-language insight card generated from the user's own data.
public struct AIInsightCardResponse: Content, Sendable {
    public var id: UUID
    public var kind: AIInsightKind
    public var title: String
    public var body: String
    public var highlights: [AIInsightHighlight]
    public var disclaimer: String
    public var generatedAt: Date

    /// Server-controlled disclaimer. Never sourced from the model.
    public static let standardDisclaimer =
        "This is educational information about your own data, not financial advice."

    public init(
        id: UUID = UUID(),
        kind: AIInsightKind,
        title: String,
        body: String,
        highlights: [AIInsightHighlight],
        disclaimer: String = AIInsightCardResponse.standardDisclaimer,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.highlights = highlights
        self.disclaimer = disclaimer
        self.generatedAt = generatedAt
    }
}
