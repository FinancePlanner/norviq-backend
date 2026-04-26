import Foundation
import StockPlanShared

/// Static metadata and tier thresholds for each badge type.
struct BadgeDefinition {
    let type: BadgeType
    let title: String
    let description: String
    let iconName: String
    let bronzeThreshold: Int
    let silverThreshold: Int
    let goldThreshold: Int

    func threshold(for tier: BadgeTier) -> Int {
        switch tier {
        case .bronze: bronzeThreshold
        case .silver: silverThreshold
        case .gold: goldThreshold
        }
    }
}

enum BadgeDefinitions {
    static let all: [BadgeDefinition] = [
        BadgeDefinition(
            type: .firstPurchase,
            title: "First Purchase",
            description: "Buy your first stock",
            iconName: "cart.fill",
            bronzeThreshold: 1,
            silverThreshold: 10,
            goldThreshold: 50
        ),
        BadgeDefinition(
            type: .newsReader,
            title: "News Reader",
            description: "Stay informed by reading stock news",
            iconName: "newspaper.fill",
            bronzeThreshold: 1,
            silverThreshold: 20,
            goldThreshold: 100
        ),
        BadgeDefinition(
            type: .investor,
            title: "Investor",
            description: "Build your portfolio with regular investments",
            iconName: "chart.line.uptrend.xyaxis",
            bronzeThreshold: 5,
            silverThreshold: 25,
            goldThreshold: 100
        ),
        BadgeDefinition(
            type: .saver,
            title: "Saver",
            description: "Maintain a positive savings rate each month",
            iconName: "banknote.fill",
            bronzeThreshold: 1,
            silverThreshold: 3,
            goldThreshold: 6
        ),
        BadgeDefinition(
            type: .frugalFun,
            title: "Frugal Fun",
            description: "Stay under your Fun spending budget",
            iconName: "face.smiling.inverse",
            bronzeThreshold: 1,
            silverThreshold: 3,
            goldThreshold: 6
        ),
        BadgeDefinition(
            type: .spendingDetox,
            title: "Spending Detox",
            description: "Go consecutive days without spending",
            iconName: "leaf.fill",
            bronzeThreshold: 2,
            silverThreshold: 5,
            goldThreshold: 10
        ),
        BadgeDefinition(
            type: .growthMindset,
            title: "Growth Mindset",
            description: "Save more money month over month",
            iconName: "arrow.up.right",
            bronzeThreshold: 1,
            silverThreshold: 3,
            goldThreshold: 6
        ),
    ]

    static func definition(for type: BadgeType) -> BadgeDefinition {
        all.first(where: { $0.type == type })!
    }
}
