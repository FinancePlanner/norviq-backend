# APNS Push Notifications

This document describes the APNS implementation for StockPlanBackend, including device registration APIs, target-price alert delivery, runtime configuration, and troubleshooting.

## Overview

The backend supports push notifications for target-price hits with these components:

- `PushNotificationsController` exposes authenticated APNS device registration/deactivation APIs.
- `PushDeviceService` stores per-user APNS device tokens and active state.
- `TargetAlertPoller` runs periodically and evaluates unresolved targets.
- `TargetAlertEvaluator` checks current prices vs target rules.
- `PushNotificationSender` delivers APNS notifications (or no-ops when APNS is not configured).

### Trigger rules

- `bull` and `base`: alert when `currentPrice >= targetPrice`
- `bear`: alert when `currentPrice <= targetPrice`

Alerts are one-shot per target revision:

- A target is marked triggered after at least one successful APNS delivery.
- Updating a target clears `alert_triggered_at` / `alert_triggered_price`.

## Environment variables

Required to enable APNS delivery:

```env
APNS_TEAM_ID=<apple_team_id>
APNS_KEY_ID=<apple_key_id>
APNS_PRIVATE_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
APNS_TOPIC=<ios_bundle_identifier>
```

Optional:

```env
APNS_ALERT_POLL_SECONDS=300
```

Notes:

- `APNS_PRIVATE_KEY_P8` supports escaped newlines (`\n`) and is normalized on startup.
- If APNS vars are missing, backend remains operational and uses a no-op sender.

## API endpoints

All endpoints require `Authorization: Bearer <token>`.

### `PUT /v1/notifications/apns/device`

Registers or updates a user device token.

Request:

```json
{
  "deviceToken": "<hex-token>",
  "platform": "ios",
  "apnsEnvironment": "development",
  "authorizationStatus": "authorized"
}
```

Response:

```json
{
  "id": "uuid",
  "deviceToken": "<hex-token>",
  "platform": "ios",
  "apnsEnvironment": "development",
  "authorizationStatus": "authorized",
  "isActive": true,
  "lastSeenAt": "2026-04-10T19:00:00.000Z"
}
```

### `POST /v1/notifications/apns/device/deactivate`

Deactivates a previously registered token.

Request:

```json
{
  "deviceToken": "<hex-token>"
}
```

Response: `200 OK`

## Data model

### `push_devices`

- `id`
- `user_id` (FK users)
- `device_token` (unique)
- `platform` (`ios`)
- `apns_environment` (`development`/`production`)
- `authorization_status` (`notDetermined`/`denied`/`authorized`/`provisional`)
- `is_active`
- `last_seen_at`
- `created_at`, `updated_at`

Indexes:

- unique `device_token`
- composite index `(user_id, is_active)`

### `targets` additions

- `alert_triggered_at` (nullable datetime)
- `alert_triggered_price` (nullable double)

## Delivery behavior and failure handling

- APNS auth uses JWT (`.p8`) with both production and development APNS clients configured.
- The sender picks APNS client by stored `apns_environment`.
- Known invalid token errors (`BadDeviceToken`, `Unregistered`, `DeviceTokenNotForTopic`) deactivate the device token.
- If all sends fail for a target, the target is not marked triggered and will be retried on future polls.

## Troubleshooting

If pushes are not delivered:

1. Verify APNS env vars are set and valid.
2. Verify `APNS_TOPIC` exactly matches the iOS app bundle identifier.
3. Confirm the registered device token is active in `push_devices`.
4. Check backend logs for APNS reason codes (`BadDeviceToken`, `Unregistered`, etc.).
5. Confirm iOS app registers with the correct APNS environment (`development` for debug builds, `production` for release/TestFlight).
