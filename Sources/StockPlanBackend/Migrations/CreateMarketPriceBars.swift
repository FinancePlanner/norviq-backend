import Fluent
import FluentSQL

struct CreateMarketPriceBars: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS market_price_bars (
            id UUID NOT NULL DEFAULT gen_random_uuid(), instrument_key TEXT NOT NULL,
            date DATE NOT NULL, open DOUBLE PRECISION NOT NULL, high DOUBLE PRECISION NOT NULL,
            low DOUBLE PRECISION NOT NULL, close DOUBLE PRECISION NOT NULL,
            adjusted_close DOUBLE PRECISION NOT NULL, volume DOUBLE PRECISION,
            currency TEXT NOT NULL, provider TEXT NOT NULL,
            created_at TIMESTAMPTZ DEFAULT NOW(), updated_at TIMESTAMPTZ,
            PRIMARY KEY (id, date), UNIQUE (instrument_key, date)
        ) PARTITION BY RANGE (date)
        """).run()
        for year in 1990 ... 2035 {
            try await sql.raw("""
            CREATE TABLE IF NOT EXISTS market_price_bars_\(unsafeRaw: String(year))
            PARTITION OF market_price_bars FOR VALUES FROM ('\(unsafeRaw: String(year))-01-01')
            TO ('\(unsafeRaw: String(year + 1))-01-01')
            """).run()
        }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_market_price_bars_lookup ON market_price_bars (instrument_key, date DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_market_price_bars_date_brin ON market_price_bars USING BRIN (date)").run()
        try await sql.raw("""
        INSERT INTO market_price_bars
            (instrument_key, date, open, high, low, close, adjusted_close, volume, currency, provider)
        SELECT UPPER(symbol), date, open, high, low, close, close, volume, 'USD', 'legacy'
        FROM price_history
        ON CONFLICT (instrument_key, date) DO NOTHING
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS market_price_bars CASCADE").run()
    }
}
