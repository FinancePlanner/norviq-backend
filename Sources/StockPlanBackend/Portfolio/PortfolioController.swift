import Vapor
import Foundation
import Fluent

struct PortfolioController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let portfolio = protected.grouped("portfolio")
        portfolio.get("summary", use: summary)
        portfolio.get("performance", use: performance)

        protected.get("transactions", use: transactions)
        protected.get("lots", use: lots)
        protected.get("pnl", use: pnl)
    }

    @Sendable
    func summary(req: Request) async throws -> PortfolioSummaryResponse {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()

        let allocation = stocks
            .map { stock in
                AllocationItem(
                    symbol: stock.symbol,
                    value: stock.shares * stock.buyPrice,
                    currency: "USD"
                )
            }
            .sorted(by: { $0.value > $1.value })

        let totalCost = allocation.reduce(0.0) { $0 + $1.value }

        return PortfolioSummaryResponse(
            baseCurrency: "USD",
            totalValue: totalCost,
            totalCost: totalCost,
            unrealizedPnl: 0,
            realizedPnl: 0,
            allocation: allocation
        )
    }

    @Sendable
    func performance(req: Request) async throws -> PortfolioPerformanceResponse {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()

        let totalValue = stocks.reduce(0.0) { $0 + ($1.shares * $1.buyPrice) }
        let today = formatISODateOnly(Date())

        return PortfolioPerformanceResponse(
            baseCurrency: "USD",
            points: [.init(date: today, value: totalValue)]
        )
    }

    @Sendable
    func transactions(req: Request) async throws -> [TransactionResponse] {
        _ = try req.auth.require(SessionToken.self)
        return []
    }

    @Sendable
    func lots(req: Request) async throws -> [LotResponse] {
        _ = try req.auth.require(SessionToken.self)
        return []
    }

    @Sendable
    func pnl(req: Request) async throws -> PnlResponse {
        let session = try req.auth.require(SessionToken.self)
        let stocks = try await Stock.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()

        let items = stocks.map {
            PnlBySymbol(symbol: $0.symbol, currency: "USD", realizedPnl: 0, unrealizedPnl: 0)
        }

        return PnlResponse(baseCurrency: "USD", items: items)
    }

    private func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
