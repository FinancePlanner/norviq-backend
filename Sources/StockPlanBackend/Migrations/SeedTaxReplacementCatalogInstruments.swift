import Fluent

struct SeedTaxReplacementCatalogInstruments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let entries = try TaxOptimizationCatalog.bundled().replacements.entries
        let entryBySymbol = Dictionary(entries.map { ($0.replacementSymbol.uppercased(), $0) }) {
            first, _ in first
        }

        for symbol in entryBySymbol.keys.sorted() {
            guard let entry = entryBySymbol[symbol] else { continue }
            let existing = try await Instrument.query(on: database)
                .filter(\.$symbol == symbol)
                .first()
            guard existing == nil else { continue }

            let instrument = Instrument(
                conid: "tax-catalog-\(symbol.lowercased())",
                symbol: symbol,
                exchange: entry.replacementExchange,
                currency: entry.replacementCurrency,
                name: entry.replacementName
            )
            instrument.instrumentType = entry.replacementInstrumentType
            try await instrument.create(on: database)
        }
    }

    func revert(on _: any Database) async throws {
        // Retain reference instruments because positions or accepted plans may depend on them.
    }
}
