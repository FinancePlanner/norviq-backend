import Vapor
import Foundation
import StockPlanShared

struct ReportsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let reports = protected.grouped("reports")
        let expenses = reports.grouped("expenses")
        
        expenses.get(use: getExpenseReports)
    }

    @Sendable
    func getExpenseReports(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        var fromDate: Date? = nil
        var toDate: Date? = nil
        
        if let from = req.query[String.self, at: "from"] {
            fromDate = dateFormatter.date(from: from)
        }
        if let to = req.query[String.self, at: "to"] {
            toDate = dateFormatter.date(from: to)
        }
        
        let granularity = req.query[String.self, at: "granularity"] ?? "month"
        
        let res = Response(status: .ok)
        
        if granularity == "year" {
            let reports = try await req.application.expensesService.getYearlyReports(
                userId: session.userId,
                from: fromDate,
                to: toDate,
                on: req.db
            )
            try res.content.encode(reports)
        } else {
            let reports = try await req.application.expensesService.getMonthlyReports(
                userId: session.userId,
                from: fromDate,
                to: toDate,
                on: req.db
            )
            try res.content.encode(reports)
        }
        
        return res
    }
}
