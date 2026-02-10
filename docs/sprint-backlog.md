# Sprint Backlog (MVP)

Scope assumptions
- Single user for v1.
- IBKR is the only broker in v1.
- Base currency configurable per account.
- Lot matching uses IBKR lot details when provided, FIFO fallback.
- FX rates use last working-day rate.

Endpoints with acceptance criteria
1. `POST /auth/register`
Acceptance: creates user; returns `token`, `userId`, `expiresIn`; rejects duplicate email; password is hashed.
2. `POST /auth/login`
Acceptance: returns `token`, `userId`, `expiresIn`; invalid credentials return 401.
3. `GET /stocks`
Acceptance: returns user holdings list sorted by symbol; supports `?symbol=` filter.
4. `POST /stocks`
Acceptance: creates holding; validates positive shares and price; returns new record.
5. `GET /stocks/:id`
Acceptance: returns holding by id; 404 if missing.
6. `PUT /stocks/:id`
Acceptance: updates holding fields; rejects invalid values; returns updated record.
7. `DELETE /stocks/:id`
Acceptance: deletes holding; 204 on success.
8. `GET /watchlist`
Acceptance: returns watchlist entries; unique by symbol.
9. `POST /watchlist`
Acceptance: adds symbol; rejects duplicates; returns entry.
10. `DELETE /watchlist/:id`
Acceptance: deletes entry; 204 on success.
11. `GET /research`
Acceptance: returns notes; supports `?symbol=` filter.
12. `POST /research`
Acceptance: creates note; requires thesis and symbol; returns note.
13. `GET /research/:id`
Acceptance: returns note; 404 if missing.
14. `PUT /research/:id`
Acceptance: updates note; returns updated note.
15. `DELETE /research/:id`
Acceptance: deletes note; 204 on success.
16. `GET /targets`
Acceptance: returns targets; supports `?symbol=` filter.
17. `POST /targets`
Acceptance: creates target; requires scenario and targetPrice.
18. `PUT /targets/:id`
Acceptance: updates target; returns updated target.
19. `DELETE /targets/:id`
Acceptance: deletes target; 204 on success.
20. `GET /quote/:symbol`
Acceptance: returns latest cached quote; cache refreshes daily; 404 for invalid symbol.
21. `GET /history/:symbol`
Acceptance: returns daily bars for 5y or 10y based on query; cached response; 404 for invalid symbol.
22. `GET /search?q=`
Acceptance: returns search results by symbol or company name.
23. `GET /fx?pair=EURUSD`
Acceptance: returns latest FX rate and date using last working-day rate.
24. `GET /portfolio/summary`
Acceptance: returns base currency, total value, total cost, realized and unrealized P&L, allocation.
25. `GET /portfolio/performance`
Acceptance: returns time-series with range filters; all values in base currency.
26. `GET /transactions`
Acceptance: supports filters `accountId`, `symbol`, `from`, `to`; returns list sorted by tradeDate desc.
27. `GET /lots`
Acceptance: supports filters `accountId`, `symbol`, `status`; returns open and closed lots.
28. `GET /pnl`
Acceptance: returns realized and unrealized P&L per symbol and totals.
29. `GET /brokers`
Acceptance: returns broker connection status for IBKR.
30. `GET /brokers/holdings`
Acceptance: returns raw IBKR holdings view for reconciliation.
31. `POST /brokers/ibkr/sync`
Acceptance: triggers sync run; returns run id; sync is idempotent.

Non-endpoint tasks
1. Migrations for all MVP tables.
Acceptance: migrations run cleanly on a new database and are reversible.
2. IBKR Gateway service.
Acceptance: headless Gateway runs and can reconnect on reboot; provides health check signal.
3. Daily sync job.
Acceptance: scheduled job runs at set time and writes a sync run log.
4. Alpha Vantage integration.
Acceptance: rate limiting and caching prevent exceeding quota.
5. FX rate integration.
Acceptance: daily ingest with cross-rate calculation.
