# Compliance And Support Runbook

This document defines the first production pass for compliance and support workflows. It is a workflow and documentation layer, not a new data export API.

Customer-facing launch drafts live in:

- `docs/legal/privacy-policy.md`
- `docs/legal/terms-of-service.md`
- `docs/legal/investment-disclaimer.md`

## Account Deletion

- Users can delete their account through the authenticated `DELETE /v1/users` endpoint.
- Support should verify the user identity before taking any manual account action.
- Account deletion should be treated as irreversible unless a database restore is explicitly performed as part of an incident.
- Account deletion hard-deletes user-owned product data where supported by the current schema.
- Billing, fraud, support, and audit records may be retained only where required for tax, refund investigation, platform compliance, fraud prevention, or incident recovery.

## Data Export Support Workflow

Until an authenticated export API exists, data export is handled as a support workflow:

1. Verify the requester controls the account email.
2. Confirm the request scope: profile, portfolio, watchlist, expenses, reports, or all user-owned records.
3. Export only records scoped to the user's UUID.
4. Package as CSV or JSON.
5. Deliver through a secure channel.
6. Record the request date, user ID, operator, exported categories, and delivery method.

Use the support export script:

```bash
DATABASE_URL=postgres://... ./scripts/ops/export_user_data.sh user@example.com
```

Do not export password hashes, refresh tokens, reset tokens, MFA challenges, OAuth secrets, APNS device tokens, or internal billing/webhook audit payloads.

## Privacy Policy Requirements

The public privacy policy must cover:

- Account identifiers and profile data collected.
- Portfolio, watchlist, expenses, goals, research, alerts, and activity data collected.
- Market-data provider usage.
- Email provider usage for MFA and password reset.
- Push notification processing.
- Crash/observability data if enabled.
- Data retention and deletion process.
- User support contact.

## Terms And Investment Disclaimer

The terms must state:

- The product is planning, tracking, and research support.
- The product does not provide financial, tax, legal, or investment advice.
- Market data may be delayed, incomplete, or unavailable.
- Users are responsible for investment decisions.
- Broker imports and CSV parsing can contain user or provider errors.

## Tax Replacement Suggestions

Replacement suggestions are explicitly advisory. Different documented benchmarks support candidate selection, but they do not determine tax treatment. The product must retain professional-review warnings because IRS wash-sale guidance centers on whether securities are "substantially identical" and applies a 30-day window before and after the sale.

Primary references used by the current US replacement catalog:

- [IRS Publication 550](https://www.irs.gov/publications/p550)
- [Vanguard S&P 500 ETF (VOO)](https://investor.vanguard.com/investment-products/etfs/profile/voo)
- [Vanguard Total Stock Market ETF (VTI)](https://investor.vanguard.com/investment-products/etfs/profile/vti)
- [Schwab U.S. Large-Cap Growth ETF (SCHG)](https://www.schwabassetmanagement.com/products/schg)
- [iShares Core Total USD Bond Market ETF (IUSB)](https://www.ishares.com/us/products/264615/ishares-core-total-usd-bond-market-etf)

These references support the transparent rule-based catalog only. They are not a legal conclusion that any proposed replacement avoids wash-sale treatment. Users remain responsible for confirming treatment with a qualified tax professional before trading or filing.

## Refund And Billing Support

- App Store subscription refunds should be handled through Apple's refund flow.
- Support can inspect server-side entitlement state once billing is implemented.
- Manual entitlement repair must require an audit note with user ID, reason, operator, timestamp, and source evidence.
- Follow `docs/support/refund-investigation.md` for refund triage.
- Follow `docs/support/audit-log.md` for data export, entitlement repair, refund, and deletion support notes.

## Retention Defaults

- Retain active account data until deletion.
- Retain operational logs according to the production logging retention policy.
- Retain backups according to the operations runbook.
- Retain billing/audit records according to tax, fraud, and platform requirements once billing is implemented.
