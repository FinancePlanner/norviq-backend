# RevenueCat Setup — Backend API

## What's already implemented

- `POST /webhooks/revenuecat` — receives events, verifies the shared secret, processes subscription lifecycle (INITIAL_PURCHASE, RENEWAL, CANCELLATION, EXPIRATION, REFUND, BILLING_ISSUE)
- `POST /billing/restore` — fetches the subscriber directly from the RevenueCat REST API and syncs entitlements
- `GET /billing/me` — returns the current billing context for the authenticated user
- `REVENUECAT_API_KEY` is set in `.env` (used by `POST /billing/restore`)
- `BYPASS_BILLING=true` in dev so the app works without a real subscription locally

---

## What's missing

### 1. Set `REVENUECAT_WEBHOOK_SECRET` in `.env`

The webhook controller rejects every incoming webhook with `503` until this is set:

```bash
# .env
REVENUECAT_WEBHOOK_SECRET=your_secret_here
```

Get the value from:

> RevenueCat Dashboard → Project Settings → Webhooks → Authorization header value

Set any strong random string there, then copy it here. The backend compares the incoming `Authorization` header against this value on every webhook call.

---

### 2. Configure the webhook URL in RevenueCat

Since the app is not deployed yet, RevenueCat cannot reach your server. For local testing use a tunnel.

**With ngrok:**

```bash
ngrok http 8080
# Outputs something like: https://abc123.ngrok.io
```

Then in RevenueCat Dashboard → Project Settings → Webhooks:

- URL: `https://abc123.ngrok.io/webhooks/revenuecat`
- Authorization header: same value as `REVENUECAT_WEBHOOK_SECRET`

**For production**, replace the ngrok URL with your real server URL:

```
https://api.yourdomain.com/webhooks/revenuecat
```

---

### 3. Verify `REVENUECAT_API_KEY` is the secret key

The key in `.env` is used by `POST /billing/restore` to call `GET https://api.revenuecat.com/v1/subscribers/:userId`.

This must be the **secret** API key (starts with `sk_`), not the public iOS key. Get it from:

> RevenueCat Dashboard → Project → API Keys → Secret keys

Verify the deployed value comes from RevenueCat Dashboard -> Project -> API Keys -> Secret keys. Do not store or paste the actual secret key in documentation.

---

## Testing the webhook locally

Once ngrok is running and the URL is set in RevenueCat:

```bash
# Trigger a test event from RevenueCat dashboard
# RevenueCat → Project Settings → Webhooks → Send Test Event

# Or simulate manually
curl -X POST http://localhost:8080/webhooks/revenuecat \
  -H "Content-Type: application/json" \
  -H "Authorization: your_webhook_secret" \
  -d '{
    "event": {
      "id": "test-event-id",
      "type": "INITIAL_PURCHASE",
      "app_user_id": "your-user-uuid",
      "product_id": "pro_yearly",
      "period_type": "NORMAL",
      "purchased_at_ms": 1714000000000,
      "expiration_at_ms": 1745536000000
    }
  }'
```

Expected response: `200 OK`

---

## Checklist

- [ ] `REVENUECAT_WEBHOOK_SECRET` set in `.env`
- [ ] Webhook URL configured in RevenueCat dashboard (ngrok for local, real URL for production)
- [ ] `REVENUECAT_API_KEY` verified as the secret `sk_...` key
- [ ] Test webhook event sent and returns `200 OK`
- [ ] `POST /billing/restore` returns correct entitlement after a test purchase

## Earnings calendar + transcripts (with audio on iOS)

- Calendar list (`/v1/market/earnings-calendar`) is a free teaser (no `earningsText` gate).
- Per-symbol earnings and transcript (`/transcript`) require Pro via `earningsText`.
- `FMP_API_KEY` is mandatory for transcript content and `hasTranscript` flags.
- iOS: audio is on-device TTS via `EarningsAudioPlayer` (background mode declared). "Listen" button appears in transcript sheets for Pro users (stock details + earnings calendar detail).
- See iOS `Documentation/revenuecat-setup.md` for matching client checklist.
