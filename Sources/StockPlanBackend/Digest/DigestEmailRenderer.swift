import Foundation

/// Renders a digest as a multipart email: a plain-text part and an HTML part
/// carrying the same sections in the same order, plus the one-click
/// unsubscribe headers (RFC 8058) that Gmail and Yahoo require of bulk senders.
struct DigestEmailRenderer: Sendable {
    struct Rendered: Equatable {
        let subject: String
        let text: String
        let html: String
        let headers: [String: String]
    }

    /// e.g. `https://norviq.org`, no trailing slash.
    let webBaseURL: String
    /// e.g. `https://api.norviq.org`, no trailing slash.
    let apiBaseURL: String

    func render(digestId: UUID, payload: DigestPayload, unsubscribeToken: String) -> Rendered {
        let sections = sections(payload)
        let token = unsubscribeToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? unsubscribeToken
        let oneClick = "\(apiBaseURL)/v1/digest/unsubscribe?token=\(token)"
        let unsubscribePage = "\(webBaseURL)/digest/unsubscribe?token=\(token)"
        let headline = DigestComposer.headline(payload)
        let footer = "Numbers come from your holdings' closing prices and your budget. Not investment advice."

        var text = "\(headline)\n\n"
        for section in sections {
            text += "\(section.title)\n"
            section.lines.forEach { text += "  \($0)\n" }
            text += "  \(link(digestId, section.anchor))\n\n"
        }
        text += "\(footer)\nUnsubscribe: \(unsubscribePage)\n"

        var html = """
        <!doctype html><html><body style="margin:0;padding:0;background:#f6f7f9;">\
        <div style="max-width:560px;margin:0 auto;padding:24px 16px;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#111827;">\
        <h1 style="font-size:20px;line-height:1.3;margin:0 0 20px;">\(escape(headline))</h1>
        """
        for section in sections {
            html += """
            <div style="background:#ffffff;border-radius:12px;padding:16px;margin:0 0 12px;">\
            <h2 style="font-size:15px;margin:0 0 8px;">\(escape(section.title))</h2>
            """
            for line in section.lines {
                html += "<p style=\"font-size:14px;line-height:1.5;margin:0 0 4px;\">\(escape(line))</p>"
            }
            html += "<a href=\"\(escape(link(digestId, section.anchor)))\" style=\"font-size:13px;color:#2563eb;\">Open in Norviq</a></div>"
        }
        html += """
        <p style="font-size:12px;color:#6b7280;line-height:1.5;margin:20px 0 0;">\(escape(footer)) \
        <a href="\(escape(unsubscribePage))" style="color:#6b7280;">Unsubscribe</a></p></div></body></html>
        """

        return Rendered(
            subject: DigestComposer.subject(payload),
            text: text,
            html: html,
            headers: [
                "List-Unsubscribe": "<\(oneClick)>",
                "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
            ]
        )
    }

    struct Section: Equatable {
        let anchor: String
        let title: String
        let lines: [String]
    }

    func sections(_ payload: DigestPayload) -> [Section] {
        var result: [Section] = []
        if !payload.holdings.isEmpty {
            var lines = payload.holdings.map { move in
                var line = "\(DigestComposer.signedMoney(move.change, currency: move.currency))"
                if let pct = move.changePercent { line += " (\(DigestComposer.signedPercent(pct)))" }
                return line + ", now \(DigestComposer.money(move.endValue, currency: move.currency))"
            }
            if payload.pricedPositions < payload.totalPositions {
                lines.append("Based on \(payload.pricedPositions) of \(payload.totalPositions) holdings with prices this week.")
            }
            result.append(Section(anchor: "holdings", title: "Your holdings this week", lines: lines))
        }
        if !payload.movers.isEmpty {
            let lines = payload.movers.map { mover in
                var line = "\(mover.symbol) \(DigestComposer.signedPercent(mover.changePercent)): "
                    + "\(DigestComposer.signedMoney(mover.contribution, currency: mover.currency))"
                if let why = mover.why, !why.isEmpty { line += ". \(why)" }
                return line
            }
            result.append(Section(anchor: "movers", title: "Top movers", lines: lines))
        }
        if let budget = payload.budget {
            let lines = budget.lines.map { line in
                let direction = line.drift > 0 ? "over" : "under"
                return "\(line.title): \(DigestComposer.money(abs(line.drift), currency: budget.currency)) \(direction) "
                    + "(\(DigestComposer.money(line.actual, currency: budget.currency)) of \(DigestComposer.money(line.target, currency: budget.currency)))"
            }
            result.append(Section(anchor: "budget", title: "Spending vs budget", lines: lines))
        }
        if let inflation = payload.inflation {
            result.append(Section(
                anchor: "inflation",
                title: "Your inflation",
                lines: ["Yours: \(MoneyFormat.percent(inflation.personalRate)) vs official \(MoneyFormat.percent(inflation.officialRate)) (\(inflation.country), \(inflation.asOf))."]
            ))
        }
        if !payload.earnings.isEmpty {
            let lines = payload.earnings.map { earning in
                "\(earning.symbol) reports on \(earning.date)\(Self.hourLabel(earning.hour))"
            }
            result.append(Section(anchor: "earnings", title: "Next week", lines: lines))
        }
        return result
    }

    private func link(_ digestId: UUID, _ anchor: String) -> String {
        "\(webBaseURL)/digest/\(digestId.uuidString.lowercased())?s=\(anchor)&src=email"
    }

    private static func hourLabel(_ hour: String?) -> String {
        switch hour {
        case "bmo": " (before open)"
        case "amc": " (after close)"
        default: ""
        }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
