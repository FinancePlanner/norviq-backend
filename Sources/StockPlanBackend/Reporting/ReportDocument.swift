import Fluent
import Foundation
import StockPlanShared

struct ReportDocument {
    struct PortfolioSection {
        let id: UUID
        let name: String
        let currency: String
        let holdings: [Holding]
        let cash: Double

        var investedValue: Double {
            holdings.reduce(0) { $0 + $1.value }
        }

        var totalValue: Double {
            investedValue + cash
        }
    }

    struct Holding {
        let symbol: String
        let shares: Double
        let price: Double
        let value: Double
        let category: String
    }

    let title: String
    let description: String?
    let generatedAt: Date
    let template: ReportTemplateInput
    let portfolios: [PortfolioSection]
}

struct ReportDocumentCollector: Sendable {
    func collect(template: ReportTemplateInput, on database: any Database) async throws -> ReportDocument {
        let ids = Set(template.blocks.flatMap(\.portfolioIds).compactMap(UUID.init(uuidString:)))
        let portfolios = ids.isEmpty
            ? []
            : try await PortfolioList.query(on: database).filter(\.$id ~~ Array(ids)).all()
        var sections = [ReportDocument.PortfolioSection]()
        for portfolio in portfolios {
            let portfolioId = try portfolio.requireID()
            let stocks = try await Stock.query(on: database)
                .filter(\.$portfolioListId == portfolioId)
                .sort(\.$symbol, .ascending)
                .all()
            let cash = try await PortfolioCashPositionRecord.query(on: database)
                .filter(\.$portfolioId == portfolioId)
                .all()
                .reduce(0) { $0 + $1.balance }
            sections.append(.init(
                id: portfolioId,
                name: portfolio.name,
                currency: portfolio.baseCurrency,
                holdings: stocks.map { stock in
                    .init(
                        symbol: stock.symbol,
                        shares: stock.shares,
                        price: stock.buyPrice,
                        value: stock.shares * stock.buyPrice,
                        category: stock.category.rawValue
                    )
                },
                cash: cash
            ))
        }
        return ReportDocument(
            title: template.name,
            description: template.description,
            generatedAt: Date(),
            template: template,
            portfolios: sections.sorted(by: { $0.name < $1.name })
        )
    }
}
