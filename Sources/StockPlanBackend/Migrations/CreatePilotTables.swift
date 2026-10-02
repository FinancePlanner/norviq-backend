import Fluent
import FluentSQL

/// Pilot follows: curated pilots, their disclosures, versioned target weights,
/// user follows, and what each follow did. Spec: docs/superpowers/specs/2026-10-01-pilot-follow-design.md.
struct CreatePilotTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilots (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            kind TEXT NOT NULL CHECK (kind IN ('politician', 'fund')),
            slug TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            chamber TEXT,
            bioguide_id TEXT,
            cik TEXT,
            name_aliases TEXT[] NOT NULL DEFAULT '{}',
            active BOOLEAN NOT NULL DEFAULT TRUE,
            last_ingested_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_disclosures (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            source_key TEXT NOT NULL,
            symbol TEXT NOT NULL,
            side TEXT NOT NULL,
            instrument TEXT NOT NULL,
            transaction_date TEXT,
            disclosure_date TEXT,
            amount_min DOUBLE PRECISION,
            amount_max DOUBLE PRECISION,
            shares DOUBLE PRECISION,
            market_value DOUBLE PRECISION,
            period TEXT,
            raw JSONB,
            discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (pilot_id, source_key)
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS pilot_disclosures_pilot_date ON pilot_disclosures (pilot_id, transaction_date)").run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_book_versions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            version INT NOT NULL,
            computed_at TIMESTAMPTZ NOT NULL,
            weights JSONB NOT NULL,
            skipped_puts INT NOT NULL DEFAULT 0,
            UNIQUE (pilot_id, version)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follows (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            target_kind TEXT NOT NULL CHECK (target_kind IN ('portfolio', 'watchlist')),
            portfolio_list_id UUID REFERENCES portfolio_lists(id) ON DELETE CASCADE,
            watchlist_list_id UUID REFERENCES watchlist_lists(id) ON DELETE CASCADE,
            starting_capital DOUBLE PRECISION,
            currency TEXT NOT NULL DEFAULT 'USD',
            applied_version INT NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused')),
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ,
            CHECK (
                (target_kind = 'portfolio' AND portfolio_list_id IS NOT NULL AND watchlist_list_id IS NULL)
                OR (target_kind = 'watchlist' AND watchlist_list_id IS NOT NULL AND portfolio_list_id IS NULL)
            )
        )
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS pilot_follows_target_unique
            ON pilot_follows (user_id, pilot_id, COALESCE(portfolio_list_id, watchlist_list_id))
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follow_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            follow_id UUID NOT NULL REFERENCES pilot_follows(id) ON DELETE CASCADE,
            book_version INT NOT NULL,
            kind TEXT NOT NULL,
            symbol TEXT NOT NULL,
            quantity DOUBLE PRECISION,
            price DOUBLE PRECISION,
            priced_at TIMESTAMPTZ NOT NULL,
            note TEXT,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (follow_id, book_version, symbol)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follow_snapshots (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            follow_id UUID NOT NULL REFERENCES pilot_follows(id) ON DELETE CASCADE,
            captured_on TIMESTAMPTZ NOT NULL,
            value DOUBLE PRECISION NOT NULL,
            cash DOUBLE PRECISION NOT NULL,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (follow_id, captured_on)
        )
        """).run()
        // CUSIP → ticker, resolved through OpenFIGI. EDGAR 13F filings carry
        // CUSIPs only. symbol NULL = looked up, no listed ticker; not retried.
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS cusip_symbols (
            cusip TEXT PRIMARY KEY,
            symbol TEXT,
            resolved_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in ["cusip_symbols", "pilot_follow_snapshots", "pilot_follow_events", "pilot_follows", "pilot_book_versions", "pilot_disclosures", "pilots"] {
            try await sql.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)").run()
        }
    }
}
