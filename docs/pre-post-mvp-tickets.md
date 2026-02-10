# StockPlan Ticket Drafts

Pre-MVP tickets
1. Auth: register and login with JWT and BCrypt.
Acceptance: `POST /auth/register` and `POST /auth/login` return a JWT, `userId`, and `expiresIn`; duplicate email is rejected; password hashing is used.
2. Core schema migrations.
Acceptance: migrations for `users`, `accounts`, `instruments`, `transactions`, `lots`, `positions`, `cash_balances`, `prices`, `fx_rates`, `broker_connections`, `research_notes`, `targets`, `watchlist_items` run cleanly.
3. IBKR Gateway service bootstrap.
Acceptance: headless IB Gateway runs on the server, reconnects on restart, and exposes a health endpoint or log heartbeat.
4. IBKR sync ingestion pipeline.
Acceptance: daily sync imports transactions, positions, cash, and dividends; sync is idempotent; manual `POST /brokers/ibkr/sync` triggers a run.
5. Lot accounting engine.
Acceptance: uses IBKR tax-lot details when provided; FIFO fallback; realized and unrealized P&L computed per lot and per symbol.
6. FX ingestion pipeline.
Acceptance: daily FX rates imported; last working-day rate used for weekends/holidays; cross-rate conversion supported.
7. Market data integration.
Acceptance: Alpha Vantage quote and history endpoints populate cache with daily refresh and retry/backoff.
8. Portfolio summary endpoint.
Acceptance: `GET /portfolio/summary` returns total value, total cost, realized/unrealized P&L, and allocation in account base currency.
9. Portfolio performance endpoint.
Acceptance: `GET /portfolio/performance` returns time-series points in base currency for the selected range.
10. Transactions endpoint.
Acceptance: `GET /transactions` supports filters for account, symbol, and date range.
11. Lots endpoint.
Acceptance: `GET /lots` returns open and closed lots with quantities and P&L in both local and base currency.
12. P&L endpoint.
Acceptance: `GET /pnl` returns realized and unrealized P&L per symbol and totals.
13. Watchlist endpoints.
Acceptance: `GET/POST/DELETE /watchlist` work and enforce unique symbols per user.
14. Research endpoints.
Acceptance: `GET/POST/PUT/DELETE /research` work and validate required thesis.
15. Targets endpoints.
Acceptance: `GET/POST/PUT/DELETE /targets` work and validate scenario and price.
16. Docker Compose for local dev.
Acceptance: `docker-compose up` runs API + Postgres + IBKR Gateway container.

Post-MVP tickets
1. WebSocket price streaming.
2. Price alerts with APNS.
3. News and RSS integration.
4. Paper trading simulator.
5. Advanced analytics (CAGR, volatility, Sharpe, attribution).
6. Multi-broker support beyond IBKR.
7. Multi-user accounts and sharing.
8. Export and tax reporting.
