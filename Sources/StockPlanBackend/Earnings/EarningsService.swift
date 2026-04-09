import Vapor

protocol EarningsService: Sendable {
    func getCalendar(query: EarningsQueryRequest, on req: Request) async throws -> [EarningsItemResponse]
}

struct DefaultEarningsService: EarningsService {
    let provider: any EarningsProvider

    func getCalendar(query: EarningsQueryRequest, on req: Request) async throws -> [EarningsItemResponse] {
        let items = try await provider.fetchCalendar(query: query, on: req)

        return items.map { item in
            EarningsItemResponse(
                date: item.date,
                epsActual: item.epsActual,
                epsEstimate: item.epsEstimate,
                hour: item.hour,
                quarter: item.quarter,
                revenueActual: item.revenueActual,
                revenueEstimate: item.revenueEstimate,
                symbol: item.symbol,
                year: item.year
            )
        }
    }
}
