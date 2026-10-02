import Fluent
import FluentSQL

/// The curated v1 pilots. Politicians are matched by bioguide ID (FMP's
/// `senateID`); aliases are a fallback for rows that arrive without one.
/// Funds are 13F filers small enough to map through unauthenticated OpenFIGI.
struct SeedPilots: AsyncMigration {
    private struct Row {
        let kind, slug, name: String
        let chamber, bioguide, cik: String?
        let aliases: [String]
    }

    private static func politician(_ slug: String, _ name: String, _ chamber: String, _ bioguide: String, _ aliases: [String]) -> Row {
        Row(kind: "politician", slug: slug, name: name, chamber: chamber, bioguide: bioguide, cik: nil, aliases: aliases)
    }

    private static func fund(_ slug: String, _ name: String, _ cik: String) -> Row {
        Row(kind: "fund", slug: slug, name: name, chamber: nil, bioguide: nil, cik: cik, aliases: [])
    }

    private static let rows: [Row] = [
        politician("nancy-pelosi", "Nancy Pelosi", "house", "P000197", ["Nancy Pelosi"]),
        politician("dan-crenshaw", "Dan Crenshaw", "house", "C001120", ["Daniel Crenshaw", "Dan Crenshaw"]),
        politician("josh-gottheimer", "Josh Gottheimer", "house", "G000583", ["Josh Gottheimer", "Joshua Gottheimer"]),
        politician("ro-khanna", "Ro Khanna", "house", "K000389", ["Ro Khanna", "Rohit Khanna"]),
        politician("michael-mccaul", "Michael McCaul", "house", "M001157", ["Michael McCaul", "Michael T. McCaul"]),
        politician("kevin-hern", "Kevin Hern", "house", "H001082", ["Kevin Hern"]),
        politician("daniel-goldman", "Daniel Goldman", "house", "G000599", ["Daniel Goldman", "Dan Goldman"]),
        politician("jared-moskowitz", "Jared Moskowitz", "house", "M001217", ["Jared Moskowitz"]),
        politician("debbie-wasserman-schultz", "Debbie Wasserman Schultz", "house", "W000797", ["Debbie Wasserman Schultz"]),
        politician("tommy-tuberville", "Tommy Tuberville", "senate", "T000278", ["Tommy Tuberville", "Thomas Tuberville"]),
        politician("shelley-moore-capito", "Shelley Moore Capito", "senate", "C001047", ["Shelley Moore Capito", "Shelley Capito"]),
        politician("sheldon-whitehouse", "Sheldon Whitehouse", "senate", "W000802", ["Sheldon Whitehouse"]),
        politician("rick-scott", "Rick Scott", "senate", "S001217", ["Rick Scott", "Richard Scott"]),
        fund("berkshire-hathaway", "Berkshire Hathaway", "0001067983"),
        fund("appaloosa", "Appaloosa Management", "0001656456"),
        fund("duquesne-family-office", "Duquesne Family Office", "0001536411"),
        fund("third-point", "Third Point", "0001040273"),
        fund("baupost", "Baupost Group", "0001061768"),
        fund("himalaya-capital", "Himalaya Capital", "0001709323"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for row in Self.rows {
            // name_aliases is TEXT[] (Task 3): Fluent stores [String] as a Postgres array.
            try await sql.raw("""
            INSERT INTO pilots (kind, slug, display_name, chamber, bioguide_id, cik, name_aliases)
            VALUES (\(bind: row.kind), \(bind: row.slug), \(bind: row.name), \(bind: row.chamber), \(bind: row.bioguide), \(bind: row.cik), \(bind: row.aliases))
            ON CONFLICT (slug) DO NOTHING
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        let slugs = Self.rows.map(\.slug)
        try await sql.raw("DELETE FROM pilots WHERE slug = ANY(\(bind: slugs))").run()
    }
}
