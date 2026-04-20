# Compliance And Support Runbook

This document defines the first production pass for compliance and support workflows. It is a workflow and documentation layer, not a new data export API.

## Account Deletion

- Users can delete their account through the authenticated `DELETE /v1/users` endpoint.
- Support should verify the user identity before taking any manual account action.
- Account deletion should be treated as irreversible unless a database restore is explicitly performed as part of an incident.
- Before launch, confirm whether deletion should be hard-delete only or whether billing/audit records must be retained separately for tax, fraud, and support purposes.

## Data Export Support Workflow

Until an authenticated export API exists, data export is handled as a support workflow:

1. Verify the requester controls the account email.
2. Confirm the request scope: profile, portfolio, watchlist, expenses, reports, or all user-owned records.
3. Export only records scoped to the user's UUID.
4. Package as CSV or JSON.
5. Deliver through a secure channel.
6. Record the request date, user ID, operator, exported categories, and delivery method.

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

## Refund And Billing Support

- App Store subscription refunds should be handled through Apple's refund flow.
- Support can inspect server-side entitlement state once billing is implemented.
- Manual entitlement repair must require an audit note with user ID, reason, operator, timestamp, and source evidence.

## Retention Defaults

- Retain active account data until deletion.
- Retain operational logs according to the production logging retention policy.
- Retain backups according to the operations runbook.
- Retain billing/audit records according to tax, fraud, and platform requirements once billing is implemented.
