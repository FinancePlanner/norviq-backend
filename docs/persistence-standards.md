# Persistence Standards

## iOS (SwiftData)

- Keep SwiftData access behind dedicated local stores/repositories; view models should not perform raw `ModelContext` CRUD.
- Treat server payloads as source of truth for synced entities (Portfolio/Watchlist).
- Reconciliation must be deterministic:
  - upsert all remote records,
  - delete local records not present remotely,
  - update `lastSyncedAt` whenever a row is inserted/updated.
- Keep writes on the app's main-actor context boundary.
- Never pass model objects across async boundaries; pass stable IDs only.

## Backend (Fluent/Postgres)

- Wrap multi-step persistence operations in explicit transactions.
- For CSV import commit, process each row in its own transaction to avoid partial row writes.
- Use idempotent migration checks for schema-scoped objects (especially enum/type creation in Postgres).
- For background evaluators (target alerts), guard state transitions with transactional re-checks before mutating trigger flags.

## Do / Don’t

- Do: `db.transaction { ... }` for multi-write paths.
- Do: fail a single CSV row without corrupting the rest of the import batch.
- Don't: mix direct persistence code across many view models/services when a focused store/repository can own it.
- Don't: rely on non-transactional read-modify-write for dedupe-sensitive flags.
