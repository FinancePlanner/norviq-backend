# IBKR Sync Design and Schedule

Goal
- Daily, reliable, idempotent ingestion of IBKR transactions, positions, cash, and dividends via a headless IB Gateway on the server.

Architecture
- Headless IB Gateway runs as a container alongside the API and Postgres.
- A sync worker process (Vapor job or a separate service) talks to IBKR API via the Gateway.
- Sync writes to staging tables or in-memory buffers, then upserts core tables in a single transaction per account.

Sync flow (high level)
1. Authenticate and ensure Gateway session is active.
2. Fetch accounts and account base currencies.
3. Fetch transactions for the last sync window.
4. Fetch current positions and cash balances.
5. Fetch dividends and corporate actions (if available via API endpoint).
6. Upsert instruments by `conid + exchange + currency`.
7. Upsert transactions using `account_id + external_id` for idempotency.
8. Rebuild lots and positions from transactions with IBKR lot details, FIFO fallback.
9. Store a sync run log and metrics.

Idempotency strategy
- Use `account_id + external_id` uniqueness for transactions.
- For positions and cash balances, upsert by `account_id + instrument_id` and `account_id + currency + as_of`.
- For instruments, upsert by `conid + exchange + currency`.

Scheduling
- Daily sync at 06:00 server local time.
- Manual trigger via `POST /brokers/ibkr/sync`.
- If a sync fails, retry up to 3 times with exponential backoff.

Operational notes
- Maintain a heartbeat log line every minute to detect stale Gateway sessions.
- Rotate IBKR session tokens on a fixed schedule if required by the Gateway.
- Emit a sync summary: counts for transactions, positions, cash, dividends, and errors.

Future enhancements
- Incremental sync windows per account.
- Reconciliation job to compare IBKR positions vs. derived positions and alert on mismatches.
