# MFA (Email OTP) - Backend + iOS Contract

## Overview
StockPlan MFA is a two-step sign-in flow:
1. Primary auth succeeds (password login or OAuth exchange).
2. Server issues an MFA challenge and sends a one-time code by email.
3. Client verifies the challenge code to receive `AuthResponse` tokens.

Phase 1 supports email OTP only. SMS is reserved for a later phase.

## API Flow

### 1) Primary sign-in
- `POST /v1/auth/login`
- `POST /v1/auth/oauth/{provider}/exchange`

For MFA-capable clients (`X-StockPlan-Client-Capabilities: mfa-auth-v1`):
- response is `AuthLoginOutcome`
  - `status=authenticated` with `auth`
  - `status=mfaRequired` with `mfa`

For legacy clients:
- if `AUTH_MFA_ALLOW_LEGACY_BYPASS=true`, the server can still return legacy `AuthResponse`.
- otherwise server returns `426 Upgrade Required`.

### 2) Verify code
- `POST /v1/auth/mfa/verify`
- body: `AuthMFAVerifyRequest`
- success: `AuthResponse`

### 3) Resend code
- `POST /v1/auth/mfa/resend`
- body: `AuthMFAResendRequest`
- success: refreshed `AuthMFAChallengeResponse`

## Security Rules
- Code TTL: `300s` (default).
- Max verify attempts: `5`.
- Resend cooldown: `30s`.
- Max resends: `3`.
- Any new challenge invalidates prior active challenges for the same user/purpose.
- Challenge state is stored in `mfa_challenges`.

## Environment Variables

### MFA
- `AUTH_MFA_ENABLED` (bool, default true in production)
- `AUTH_MFA_ALLOW_LEGACY_BYPASS` (bool, default false in production)
- `AUTH_MFA_CODE_TTL_SECONDS` (default `300`)
- `AUTH_MFA_MAX_VERIFY_ATTEMPTS` (default `5`)
- `AUTH_MFA_RESEND_COOLDOWN_SECONDS` (default `30`)
- `AUTH_MFA_MAX_RESENDS` (default `3`)

### Email Provider (Resend)
- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`
- `RESEND_BASE_URL` (optional; default `https://api.resend.com`)

If MFA is enabled in production and Resend config is missing, server boot fails.

## Data Model
Table: `mfa_challenges`
- `id`, `user_id`, `purpose`, `channel`, `destination`, `code_hash`
- `expires_at`, `consumed_at`
- `failed_attempts`, `resend_count`, `last_sent_at`
- timestamps

Indexes:
- `user_id`
- `expires_at`
- `user_id + purpose + consumed_at`

## iOS Integration Notes
- iOS login and OAuth exchange send capability header: `mfa-auth-v1`.
- UI flow:
  - primary sign-in
  - show MFA code sheet when `status=mfaRequired`
  - call `/v1/auth/mfa/verify`
  - store session only after verify succeeds

## Troubleshooting
- `401` on verify: invalid code, expired challenge, or consumed challenge.
- `429` on resend/verify: throttling, cooldown, or resend cap reached.
- `426` on login: strict MFA enabled and client is not capability-aware.
