# Support Audit Log Procedure

Support actions that affect user data or billing state must leave an audit note before the action is performed.

## Required Fields

- Timestamp in UTC.
- Operator name or account.
- User ID and account email.
- Action type: data export, entitlement repair, refund investigation, account deletion support, or incident recovery.
- Source evidence: user request, App Store reference, RevenueCat customer/event ID, backend record ID, or incident ticket.
- Before state.
- Action taken.
- After state.
- Delivery channel when user data is exported.

## Template: Data Export Request

```text
timestamp_utc:
operator:
user_id:
email:
request_source:
identity_verification:
export_path:
export_checksum:
excluded_categories:
delivery_channel:
delivery_confirmed_at:
notes:
```

## Template: Manual Entitlement Repair

```text
timestamp_utc:
operator:
user_id:
email:
source_evidence:
revenuecat_customer_id:
provider_event_id:
before_entitlement:
before_subscription:
action_taken:
after_entitlement:
after_subscription:
notes:
```

## Template: Refund Investigation

```text
timestamp_utc:
operator:
user_id:
email:
app_store_reference:
revenuecat_customer_id:
provider_event_ids:
billing_events_reviewed:
subscription_before:
entitlement_before:
finding:
handoff_destination:
notes:
```

## Template: Account Deletion Support Case

```text
timestamp_utc:
operator:
user_id:
email:
request_source:
identity_verification:
deletion_path:
retained_records:
completed_at:
notes:
```
