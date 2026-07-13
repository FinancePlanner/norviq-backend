import Foundation

struct ReportHTMLRenderer: Sendable {
    func render(_ document: ReportDocument) -> String {
        let cards = document.portfolios.map { portfolio in
            let rows = portfolio.holdings.map { holding in
                """
                <tr><td>\(escape(holding.symbol))</td><td>\(escape(holding.category.capitalized))</td><td class="num">\(number(holding.shares))</td><td class="num">\(money(holding.value, portfolio.currency))</td></tr>
                """
            }.joined()
            return """
            <section class="portfolio">
              <div class="section-head"><div><p class="eyebrow">Portfolio</p><h2>\(escape(portfolio.name))</h2></div><div class="metric"><span>Total value</span><strong>\(money(portfolio.totalValue, portfolio.currency))</strong></div></div>
              <div class="metrics"><div><span>Invested</span><b>\(money(portfolio.investedValue, portfolio.currency))</b></div><div><span>Cash</span><b>\(money(portfolio.cash, portfolio.currency))</b></div><div><span>Holdings</span><b>\(portfolio.holdings.count)</b></div></div>
              <table><thead><tr><th>Symbol</th><th>Asset class</th><th class="num">Shares</th><th class="num">Value</th></tr></thead><tbody>\(rows)</tbody></table>
            </section>
            """
        }.joined()
        let generated = ISO8601DateFormatter().string(from: document.generatedAt)
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        @page { size: A4; margin: 18mm 16mm 20mm; @bottom-right { content: "Norviq | " counter(page) " / " counter(pages); color: #727b72; font-size: 9px; } }
        * { box-sizing: border-box; } body { margin: 0; color: #172019; font: 12px -apple-system, BlinkMacSystemFont, "Inter", sans-serif; background: #fff; }
        header { padding: 32px; border-radius: 18px; color: #f5f7f2; background: linear-gradient(135deg,#14291d,#32543c); margin-bottom: 22px; }
        .brand { letter-spacing: .16em; text-transform: uppercase; font-size: 10px; opacity: .75; } h1 { font: 34px Georgia, serif; margin: 28px 0 8px; } header p { max-width: 70%; color: #d7e2d8; }
        .meta { margin-top: 28px; color: #b9c9bd; font-size: 10px; } .portfolio { page-break-inside: avoid; margin: 0 0 24px; border: 1px solid #dfe5df; border-radius: 14px; padding: 20px; }
        .section-head { display:flex; justify-content:space-between; align-items:flex-start; } .eyebrow { color:#68736b; margin:0 0 4px; text-transform:uppercase; letter-spacing:.13em; font-size:9px; } h2 { font: 24px Georgia,serif; margin:0; }
        .metric { text-align:right; } .metric span,.metrics span { display:block; color:#68736b; font-size:10px; } .metric strong { font-size:20px; }
        .metrics { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; margin:18px 0; } .metrics div { background:#f3f5f1; border-radius:10px; padding:11px; } .metrics b { font-size:14px; }
        table { width:100%; border-collapse:collapse; } th { color:#68736b; font-size:9px; letter-spacing:.08em; text-transform:uppercase; text-align:left; border-bottom:1px solid #cad3ca; padding:8px 6px; } td { border-bottom:1px solid #edf0ec; padding:8px 6px; } .num { text-align:right; }
        footer { color:#727b72; font-size:9px; margin-top:18px; } </style></head><body>
        <header><div class="brand">Norviq Advanced Reporting</div><h1>\(escape(document.title))</h1><p>\(escape(document.description ?? "A composed view of your selected portfolios."))</p><div class="meta">Generated \(escape(generated))</div></header>
        \(cards)
        <footer>Educational information only. Values reflect available portfolio records and user-entered assumptions at generation time.</footer>
        </body></html>
        """
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func money(_ value: Double, _ currency: String) -> String {
        "\(currency) \(String(format: "%.2f", value))"
    }
}
