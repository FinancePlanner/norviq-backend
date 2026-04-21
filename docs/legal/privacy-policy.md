# Privacy Policy

Effective date: Launch draft

This Privacy Policy describes how StockPlan collects, uses, stores, and deletes information for the StockPlan app and API.

## Information We Collect

We collect account identifiers such as email address, username, authentication metadata, and profile fields you choose to provide. We collect portfolio, watchlist, valuation, expense, goal, report, alert, activity, and feedback data that you create in the app.

When subscriptions are enabled, we process billing state from RevenueCat and App Store subscription events. We store subscription status, entitlement level, product identifiers, event identifiers, and audit metadata needed to provide access, investigate billing issues, and prevent fraud. Raw billing provider payloads are internal operational records and are not included in standard user exports.

If enabled, we process email delivery metadata for password reset and MFA, APNS device tokens for push notifications, and operational telemetry such as request IDs, error logs, traces, and service health signals.

## How We Use Information

We use your information to provide account access, portfolio tracking, watchlists, research tools, alerts, reporting, subscription entitlements, support, abuse prevention, debugging, and service reliability.

We do not sell personal information. We do not use your portfolio or financial records to provide individualized investment, legal, tax, or financial advice.

## Third-Party Processors

The service may use infrastructure, email, push notification, billing, market-data, and observability providers. These providers process data only as needed to operate the app, deliver notifications, provide subscription status, retrieve market data, or monitor reliability.

## Data Retention

Active account data is retained while the account exists. Account deletion hard-deletes user-owned product data from the application database where supported by the current schema. Billing, fraud, audit, backup, and operational records may be retained where required for tax, legal, fraud prevention, refund investigation, platform compliance, or incident recovery.

Encrypted backups are retained according to the operations runbook. Operational logs and telemetry are retained according to the configured production logging and observability retention settings.

## Data Export

For launch, data export is handled through support. We verify account ownership, export user-owned product records, exclude secrets and internal security credentials, package the export, and deliver it through a secure channel.

## Account Deletion

Users can request deletion through the app flow backed by `DELETE /v1/users`, or through support if account access is unavailable. Deletion is irreversible except through incident recovery from backups.

## Security

The backend uses authenticated APIs, production secret checks, encrypted profile fields, private database and Redis networking, structured logs, and operational monitoring. No system can guarantee absolute security.

## Contact

For privacy, data export, or deletion requests, contact support through the published StockPlan support channel.
