# IBKR Read-Only Guarantee

Norviq's Interactive Brokers integration is **strictly read-only**. Norviq can
read portfolio and account data to display it; it can never place trades,
transfer funds, or modify anything at the brokerage. This document records how
that guarantee is enforced in code so it can be audited and kept true as the
integration evolves.

## 1. OAuth scope is constrained at startup

The scope requested from IBKR is read-only. `IBKR_OAUTH_SCOPE` is validated when
the OAuth configuration loads (`Broker/IBKROAuthClient.swift`,
`IBKROAuthConfiguration.assertReadOnlyScope`). If the configured scope contains
any write-capable token, the app **fails to start** rather than requesting more
than read access.

Rejected scope tokens (substring match, case-insensitive):

```
trade, trading, order, orders, write,
transfer, transfers, payment, payments, place, modify
```

Regression tests live in `Tests/StockPlanBackendTests/IBKROAuthClientTests.swift`
(`readOnlyScopeGuardAcceptsReadScopes`, `readOnlyScopeGuardRejectsWriteScopes`).

## 2. No endpoint can write to the brokerage

Every route in `Broker/BrokerController.swift` either reads from IBKR or mutates
**only Norviq's own database** — none issues a trade, order, or transfer to
IBKR:

| Route | Effect |
| --- | --- |
| `GET /v1/brokers` | Read: list the user's broker connections |
| `GET /v1/brokers/holdings` | Read: list imported holdings from Norviq's DB |
| `GET /v1/brokers/:provider` | Read: one connection's status |
| `POST /v1/brokers/import/csv[/commit]` | Write to Norviq's DB only (CSV upload) |
| `POST /v1/brokers/ibkr/connect/start` | Begin read-only OAuth |
| `POST /v1/brokers/ibkr/sync` | Read from IBKR, upsert into Norviq's DB |
| `GET /v1/brokers/ibkr/sync/status` | Read: sync health |
| `DELETE /v1/brokers/ibkr/connection` | Delete Norviq-local connection + imported holdings |

The IBKR gateway client (`Broker/IBKRBrokerIntegration.swift`) performs GET
requests only. Disconnecting deletes the local connection and the
`source_provider = ibkr` holdings; it does not touch anything at IBKR.

## 3. Credentials are encrypted at rest

Broker access/refresh tokens are stored encrypted via `TokenEncryptionService`
(`Security/CredentialEncryption.swift`, AES-GCM with per-context AAD). Tokens are
decrypted only at the point of an outbound IBKR read call and are never included
in any response DTO.

## Auditing checklist

When changing the broker integration, confirm:

1. No new route issues a write/trade/transfer/payment call to IBKR.
2. Any new outbound IBKR call is a read (GET) or an OAuth token exchange.
3. `IBKR_OAUTH_SCOPE` still passes `assertReadOnlyScope` in every environment.
4. New broker credentials are stored through `TokenEncryptionService`, never in
   plaintext, and never serialized into a DTO.
