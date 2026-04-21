# Refund Investigation Runbook

Refunds for App Store subscriptions are handled through Apple's refund flow. Backend support is responsible for verifying entitlement state and explaining what the server currently believes.

## Evidence Sources

- App Store refund or transaction reference supplied by the user.
- RevenueCat customer profile and event timeline.
- Backend `billing_events` rows by `provider_event_id`, `event_type`, and `user_id`.
- Backend `subscriptions` row by `user_id` or provider transaction ID.
- Backend `entitlements` row by `user_id`.

## Procedure

1. Verify the requester controls the account email.
2. Locate the user ID.
3. Search RevenueCat for the customer and transaction evidence.
4. Search backend `billing_events` for matching provider event IDs and event types.
5. Compare `subscriptions.status`, `period_ends_at`, `cancelled_at`, and `entitlements.level`.
6. If RevenueCat/App Store shows a refund but backend entitlement is still premium, create an audit note before repair.
7. If backend processed the refund correctly, direct the user to Apple's refund status flow.
8. Record the final finding in the support audit log.

## Manual Repair Guardrails

- Do not grant premium from a user screenshot alone.
- Do not delete `billing_events`.
- Do not edit raw provider payloads.
- Link every manual entitlement change to source evidence and an audit note.
