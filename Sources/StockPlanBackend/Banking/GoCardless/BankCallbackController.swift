import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Handles the GoCardless hosted-link redirect. GoCardless sends the user here
/// after consent; we confirm the requisition, create the connection, and bounce
/// the user back to the app/web via the stored redirect URI. Unauthenticated
/// (the request originates from the bank redirect), so it relies on the
/// single-use, time-limited BankLinkFlow reference.
struct BankCallbackController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1", "banks", "gocardless").get("callback", use: callback)
    }

    @Sendable
    func callback(req: Request) async throws -> Response {
        let reference = (req.query[String.self, at: "ref"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let providerError = req.query[String.self, at: "error"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !reference.isEmpty,
              let flow = try await BankLinkFlow.query(on: req.db)
              .filter(\.$reference == reference)
              .first()
        else {
            throw Abort(.badRequest, reason: "Unknown bank link reference.")
        }

        let base = flow.appRedirectURI
        if let providerError, !providerError.isEmpty {
            return redirect(to: appURL(base: base, status: "error", message: providerError))
        }

        do {
            let provider = try req.bankProviderRegistry.provider(for: .gocardless)
            _ = try await provider.completeHostedLink(reference: reference, on: req)
            return redirect(to: appURL(base: base, status: "connected", message: nil))
        } catch {
            let message = (error as? any AbortError)?.reason ?? error.localizedDescription
            return redirect(to: appURL(base: base, status: "error", message: message))
        }
    }

    private func redirect(to url: String) -> Response {
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: url)
        return response
    }

    private func appURL(base: String, status: String, message: String?) -> String {
        var components = URLComponents(string: base) ?? URLComponents()
        var items = components.queryItems ?? []
        items.append(.init(name: "bank", value: status))
        if let message, !message.isEmpty {
            items.append(.init(name: "error", value: message))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? base
    }
}
