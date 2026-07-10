import Foundation
import StockPlanShared
import Vapor

struct ChartBuilderRequest {
    let symbol: String
    let metricKeys: [String]
    let period: ChartBuilderPeriodKind
    let limit: Int
    let compare: [String]

    var allSymbols: [String] {
        [symbol] + compare
    }
}

struct ChartBuilderStatementBundle {
    var income: [IncomeStatementResponse] = []
    var balance: [BalanceSheetStatementResponse] = []
    var cashFlow: [CashFlowStatementResponse] = []
    var ratios: [RatiosResponse] = []
    var growth: [FinancialGrowthResponse] = []
}

protocol ChartBuilderService: Sendable {
    func build(_ request: ChartBuilderRequest, on req: Request) async throws -> ChartBuilderResponse
}

struct DefaultChartBuilderService: ChartBuilderService {
    static let maxMetrics = 20
    static let maxCompareSymbols = 3
    static let maxLimit = 40

    // MARK: - Request parsing

    static func parseRequest(
        symbol: String,
        metricsQuery: String?,
        periodQuery: String?,
        limitQuery: Int?,
        compareQuery: String?
    ) throws -> ChartBuilderRequest {
        let metricKeys = (metricsQuery ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !metricKeys.isEmpty else {
            throw Abort(.badRequest, reason: "At least one metric is required (metrics=key1,key2).")
        }
        guard metricKeys.count <= maxMetrics else {
            throw Abort(.badRequest, reason: "Chart builder supports at most \(maxMetrics) metrics per request.")
        }

        let unknown = metricKeys.filter { ChartBuilderMetricCatalog.byKey[$0] == nil }
        guard unknown.isEmpty else {
            throw Abort(.badRequest, reason: "Unknown metric keys: \(unknown.joined(separator: ", ")).")
        }

        let period: ChartBuilderPeriodKind
        switch periodQuery?.lowercased() {
        case nil, "annual": period = .annual
        case "quarter", "quarterly": period = .quarter
        case "ttm": period = .ttm
        default:
            throw Abort(.badRequest, reason: "Invalid period. Use annual, quarter, or ttm.")
        }

        if period == .ttm {
            let unsupported = metricKeys.filter { ChartBuilderMetricCatalog.byKey[$0]?.supportsTTM == false }
            guard unsupported.isEmpty else {
                throw Abort(
                    .badRequest,
                    reason: "Metrics not supported for TTM: \(unsupported.joined(separator: ", "))."
                )
            }
        }

        let defaultLimit = period == .annual ? 10 : 20
        let limit = min(max(limitQuery ?? defaultLimit, 1), maxLimit)

        let compare = (compareQuery ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && $0 != symbol.uppercased() }
        guard compare.count <= maxCompareSymbols else {
            throw Abort(.badRequest, reason: "Chart builder supports at most \(maxCompareSymbols) compare symbols.")
        }

        return ChartBuilderRequest(
            symbol: symbol.uppercased(),
            metricKeys: metricKeys,
            period: period,
            limit: limit,
            compare: compare
        )
    }

    // MARK: - Build

    func build(_ request: ChartBuilderRequest, on req: Request) async throws -> ChartBuilderResponse {
        let sources = ChartBuilderMetricResolver.requiredSources(
            for: request.metricKeys,
            period: request.period
        )
        // TTM series are assembled from quarterly statements; the rolling
        // 4-quarter window needs 3 extra leading quarters.
        let statementPeriod = request.period == .annual ? "annual" : "quarter"
        let statementLimit = request.period == .ttm ? request.limit + 3 : request.limit

        var bundles: [String: ChartBuilderStatementBundle] = [:]
        var companies: [String: ChartBuilderCompany] = [:]

        try await withThrowingTaskGroup(
            of: (String, ChartBuilderStatementBundle, ChartBuilderCompany).self
        ) { group in
            for symbol in request.allSymbols {
                group.addTask {
                    let bundle = try await Self.fetchBundle(
                        symbol: symbol,
                        sources: sources,
                        period: statementPeriod,
                        limit: statementLimit,
                        on: req
                    )
                    let profile = try? await req.application.marketDataService.profile(symbol: symbol, on: req)
                    let currency = bundle.income.first?.reportedCurrency
                        ?? bundle.cashFlow.first?.reportedCurrency
                        ?? bundle.balance.first?.reportedCurrency
                        ?? profile?.currency
                    let company = ChartBuilderCompany(symbol: symbol, name: profile?.name, currency: currency)
                    return (symbol, bundle, company)
                }
            }
            for try await (symbol, bundle, company) in group {
                bundles[symbol] = bundle
                companies[symbol] = company
            }
        }

        return Self.assemble(request: request, bundles: bundles, companies: companies)
    }

    private static func fetchBundle(
        symbol: String,
        sources: Set<ChartBuilderSource>,
        period: String,
        limit: Int,
        on req: Request
    ) async throws -> ChartBuilderStatementBundle {
        var bundle = ChartBuilderStatementBundle()
        let service = req.application.marketDataService
        if sources.contains(.income) {
            bundle.income = try await service.incomeStatement(symbol: symbol, limit: limit, period: period, on: req)
        }
        if sources.contains(.balance) {
            bundle.balance = try await service.balanceSheetStatement(symbol: symbol, limit: limit, period: period, on: req)
        }
        if sources.contains(.cashFlow) {
            bundle.cashFlow = try await service.cashFlowStatement(symbol: symbol, limit: limit, period: period, on: req)
        }
        if sources.contains(.ratios) {
            bundle.ratios = try await service.ratios(symbol: symbol, limit: limit, period: period, on: req)
        }
        if sources.contains(.growth) {
            bundle.growth = try await service.financialGrowth(symbol: symbol, limit: limit, period: period, on: req)
        }
        return bundle
    }

    // MARK: - Assembly (pure)

    private struct PeriodEntry {
        let key: String
        let endDate: String
        let fiscalYear: String?
        let fiscalPeriod: String?
    }

    static func assemble(
        request: ChartBuilderRequest,
        bundles: [String: ChartBuilderStatementBundle],
        companies: [String: ChartBuilderCompany]
    ) -> ChartBuilderResponse {
        let quarterly = request.period != .annual
        let primaryBundle = bundles[request.symbol] ?? ChartBuilderStatementBundle()
        var entries = periodEntries(from: primaryBundle, quarterly: quarterly)

        if request.period == .ttm {
            // Rolling window needs 3 warm-up quarters; only the tail is emitted.
            entries = Array(entries.suffix(request.limit + 3))
        } else {
            entries = Array(entries.suffix(request.limit))
        }

        var rowsBySymbol: [String: [String: ChartBuilderPeriodRow]] = [:]
        for symbol in request.allSymbols {
            rowsBySymbol[symbol] = periodRows(from: bundles[symbol] ?? ChartBuilderStatementBundle(), quarterly: quarterly)
        }

        let emittedEntries = request.period == .ttm ? Array(entries.dropFirst(min(3, entries.count))) : entries
        let periods = emittedEntries.map { entry in
            ChartBuilderPeriod(
                label: periodLabel(entry: entry, kind: request.period),
                fiscalYear: entry.fiscalYear,
                fiscalPeriod: entry.fiscalPeriod,
                endDate: entry.endDate
            )
        }

        var series: [ChartBuilderSeries] = []
        for symbol in request.allSymbols {
            let rows = rowsBySymbol[symbol] ?? [:]
            for key in request.metricKeys {
                guard let descriptor = ChartBuilderMetricCatalog.byKey[key],
                      let binding = ChartBuilderMetricResolver.binding(for: key)
                else { continue }

                let values: [Double?] = if request.period == .ttm {
                    ttmValues(
                        descriptor: descriptor,
                        binding: binding,
                        entries: entries,
                        rows: rows,
                        emittedCount: periods.count
                    )
                } else {
                    emittedEntries.map { entry in
                        rows[entry.key].flatMap(binding.extract)
                    }
                }

                let currency = descriptor.format == .currency || descriptor.format == .perShare
                    ? companies[symbol]?.currency
                    : nil
                series.append(
                    ChartBuilderSeries(
                        symbol: symbol,
                        metricKey: key,
                        label: descriptor.label,
                        format: descriptor.format,
                        currency: currency,
                        values: values,
                        growth: growthStats(values: values, periods: periods, kind: request.period)
                    )
                )
            }
        }

        let companyList = request.allSymbols.compactMap { companies[$0] }
        return ChartBuilderResponse(
            period: request.period,
            periods: periods,
            series: series,
            companies: companyList
        )
    }

    /// Ordered period axis (oldest → newest) unioned across the sources
    /// present in a bundle.
    private static func periodEntries(
        from bundle: ChartBuilderStatementBundle,
        quarterly: Bool
    ) -> [PeriodEntry] {
        var byKey: [String: PeriodEntry] = [:]

        func register(date: String, fiscalYear: String?, fiscalPeriod: String?) {
            let key = periodKey(date: date, fiscalYear: fiscalYear, fiscalPeriod: fiscalPeriod, quarterly: quarterly)
            if byKey[key] == nil {
                byKey[key] = PeriodEntry(key: key, endDate: date, fiscalYear: fiscalYear, fiscalPeriod: fiscalPeriod)
            }
        }

        for row in bundle.income {
            register(date: row.date, fiscalYear: row.fiscalYear, fiscalPeriod: row.period)
        }
        for row in bundle.balance {
            register(date: row.date, fiscalYear: row.fiscalYear, fiscalPeriod: row.period)
        }
        for row in bundle.cashFlow {
            register(date: row.date, fiscalYear: row.fiscalYear, fiscalPeriod: row.period)
        }
        for row in bundle.ratios {
            register(date: row.date, fiscalYear: row.fiscalYear, fiscalPeriod: row.period)
        }
        for row in bundle.growth {
            register(date: row.date, fiscalYear: row.fiscalYear, fiscalPeriod: row.period)
        }

        // ISO yyyy-MM-dd sorts lexically.
        return byKey.values.sorted { $0.endDate < $1.endDate }
    }

    private static func periodRows(
        from bundle: ChartBuilderStatementBundle,
        quarterly: Bool
    ) -> [String: ChartBuilderPeriodRow] {
        var rows: [String: ChartBuilderPeriodRow] = [:]

        func row(date: String, fiscalYear: String?, fiscalPeriod: String?) -> String {
            periodKey(date: date, fiscalYear: fiscalYear, fiscalPeriod: fiscalPeriod, quarterly: quarterly)
        }

        for item in bundle.income {
            rows[row(date: item.date, fiscalYear: item.fiscalYear, fiscalPeriod: item.period), default: ChartBuilderPeriodRow()].income = item
        }
        for item in bundle.balance {
            rows[row(date: item.date, fiscalYear: item.fiscalYear, fiscalPeriod: item.period), default: ChartBuilderPeriodRow()].balance = item
        }
        for item in bundle.cashFlow {
            rows[row(date: item.date, fiscalYear: item.fiscalYear, fiscalPeriod: item.period), default: ChartBuilderPeriodRow()].cashFlow = item
        }
        for item in bundle.ratios {
            rows[row(date: item.date, fiscalYear: item.fiscalYear, fiscalPeriod: item.period), default: ChartBuilderPeriodRow()].ratios = item
        }
        for item in bundle.growth {
            rows[row(date: item.date, fiscalYear: item.fiscalYear, fiscalPeriod: item.period), default: ChartBuilderPeriodRow()].growth = item
        }
        return rows
    }

    /// Alignment key: fiscal year (plus fiscal period when quarterly).
    /// Falls back to the calendar year of the end date when FMP omits
    /// fiscal metadata.
    static func periodKey(date: String, fiscalYear: String?, fiscalPeriod: String?, quarterly: Bool) -> String {
        let year = fiscalYear ?? String(date.prefix(4))
        guard quarterly else { return year }
        let quarter = fiscalPeriod ?? String(date.prefix(7))
        return "\(year)-\(quarter)"
    }

    private static func periodLabel(entry: PeriodEntry, kind: ChartBuilderPeriodKind) -> String {
        let year = entry.fiscalYear ?? String(entry.endDate.prefix(4))
        switch kind {
        case .annual:
            return "FY\(year)"
        case .quarter:
            return "\(entry.fiscalPeriod ?? "Q?") \(year)"
        case .ttm:
            return "TTM \(entry.fiscalPeriod ?? "Q?") \(year)"
        }
    }

    // MARK: - TTM

    private static func ttmValues(
        descriptor: ChartMetricDescriptor,
        binding: ChartBuilderMetricBinding,
        entries: [PeriodEntry],
        rows: [String: ChartBuilderPeriodRow],
        emittedCount: Int
    ) -> [Double?] {
        let quarterlyValues: [Double?]
        switch descriptor.aggregation {
        case .flow:
            let raw = entries.map { rows[$0.key].flatMap(binding.extract) }
            quarterlyValues = rollingFourQuarterSums(values: raw, dates: entries.map(\.endDate))
        case .pointInTime:
            quarterlyValues = entries.map { rows[$0.key].flatMap(binding.extract) }
        case .ratio:
            guard let components = binding.ttmComponents,
                  let numerator = ChartBuilderMetricResolver.binding(for: components.numerator),
                  let denominator = ChartBuilderMetricResolver.binding(for: components.denominator)
            else {
                quarterlyValues = Array(repeating: nil, count: entries.count)
                break
            }
            let dates = entries.map(\.endDate)
            let numeratorTTM = rollingFourQuarterSums(
                values: entries.map { rows[$0.key].flatMap(numerator.extract) },
                dates: dates
            )
            let denominatorTTM = rollingFourQuarterSums(
                values: entries.map { rows[$0.key].flatMap(denominator.extract) },
                dates: dates
            )
            quarterlyValues = zip(numeratorTTM, denominatorTTM).map { num, den in
                guard let num, let den, den != 0 else { return nil }
                return num / den
            }
        }
        return Array(quarterlyValues.suffix(emittedCount))
    }

    /// Rolling 4-quarter sums. A window is valid only when all 4 values are
    /// present and the quarters are consecutive (window span ≤ 380 days).
    static func rollingFourQuarterSums(values: [Double?], dates: [String]) -> [Double?] {
        let parsed = dates.map(parseDate)
        return values.indices.map { index in
            guard index >= 3 else { return nil }
            let window = values[(index - 3) ... index]
            guard !window.contains(where: { $0 == nil }) else { return nil }
            if let start = parsed[index - 3], let end = parsed[index] {
                let span = end.timeIntervalSince(start)
                guard span <= 380 * 86400 else { return nil }
            }
            return window.compactMap(\.self).reduce(0, +)
        }
    }

    // MARK: - Growth stats

    static func growthStats(
        values: [Double?],
        periods: [ChartBuilderPeriod],
        kind: ChartBuilderPeriodKind
    ) -> ChartBuilderGrowthStats? {
        guard values.contains(where: { $0 != nil }) else { return nil }

        let yoyLag = kind == .annual ? 1 : 4
        var yoy: [ChartBuilderGrowthPoint] = []
        for index in values.indices {
            guard index >= yoyLag,
                  let current = values[index],
                  let base = values[index - yoyLag]
            else { continue }
            let absolute = current - base
            let percent: Double? = base > 0 ? absolute / base : nil
            yoy.append(
                ChartBuilderGrowthPoint(
                    periodLabel: periods.indices.contains(index) ? periods[index].label : "",
                    absolute: absolute,
                    percent: percent
                )
            )
        }

        guard let firstIndex = values.firstIndex(where: { $0 != nil }),
              let lastIndex = values.lastIndex(where: { $0 != nil }),
              firstIndex < lastIndex,
              let first = values[firstIndex],
              let last = values[lastIndex]
        else {
            return ChartBuilderGrowthStats(yoy: yoy, totalChange: nil, totalChangePercent: nil, cagr: nil)
        }

        let totalChange = last - first
        let totalChangePercent: Double? = first > 0 ? totalChange / first : nil

        var cagr: Double?
        if first > 0, last > 0,
           periods.indices.contains(firstIndex), periods.indices.contains(lastIndex),
           let startDate = parseDate(periods[firstIndex].endDate),
           let endDate = parseDate(periods[lastIndex].endDate)
        {
            let years = endDate.timeIntervalSince(startDate) / (365.25 * 86400)
            if years >= 1 {
                cagr = pow(last / first, 1 / years) - 1
            }
        }

        return ChartBuilderGrowthStats(
            yoy: yoy,
            totalChange: totalChange,
            totalChangePercent: totalChangePercent,
            cagr: cagr
        )
    }

    // MARK: - CSV

    static func makeCSV(response: ChartBuilderResponse) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let comparing = Set(response.series.map(\.symbol)).count > 1

        var header = ["Period", "Fiscal Year"]
        for series in response.series {
            var column = comparing ? "\(series.symbol) \(series.label)" : series.label
            if series.format == .percent {
                column += " (%)"
            }
            header.append(column)
        }

        var lines = [header.map(escapeCSVField).joined(separator: ",")]
        for (index, period) in response.periods.enumerated() {
            var fields = [period.label, period.fiscalYear ?? ""]
            for series in response.series {
                if let value = series.values.indices.contains(index) ? series.values[index] : nil {
                    fields.append(formatCSVValue(value))
                } else {
                    fields.append("")
                }
            }
            lines.append(fields.map(escapeCSVField).joined(separator: ","))
        }

        var data = Data(bom)
        data.append(Data(lines.joined(separator: "\n").utf8))
        data.append(Data("\n".utf8))
        return data
    }

    static func csvFilename(symbol: String, period: ChartBuilderPeriodKind) -> String {
        "\(symbol.uppercased())-chart-builder-\(period.rawValue).csv"
    }

    private static func formatCSVValue(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func escapeCSVField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Dates

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: String(string.prefix(10)))
    }
}

extension Application {
    struct ChartBuilderServiceKey: StorageKey {
        typealias Value = any ChartBuilderService
    }

    var chartBuilderService: any ChartBuilderService {
        get { storage[ChartBuilderServiceKey.self] ?? DefaultChartBuilderService() }
        set { storage[ChartBuilderServiceKey.self] = newValue }
    }
}
