# OAuth Setup (Backend)

This document lists the minimum required configuration for OAuth to work end-to-end with the current backend implementation, including **StockPlanWeb** browser callbacks.

## Supported providers (current state)

- `apple` is implemented.
- `google` is implemented.
- `x` is implemented.

## Required environment variables

Set these variables on the backend runtime (see [`.env.example`](../.env.example)):

```env
OAUTH_APPLE_CLIENT_ID=your-apple-services-id
OAUTH_APPLE_TEAM_ID=your-apple-team-id
OAUTH_APPLE_KEY_ID=your-apple-signing-key-id
OAUTH_APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"

OAUTH_GOOGLE_CLIENT_ID=your-google-oauth-client-id
OAUTH_GOOGLE_CLIENT_SECRET=your-google-oauth-client-secret

OAUTH_X_CLIENT_ID=your-x-client-id
# optional if your X app is configured as confidential client
OAUTH_X_CLIENT_SECRET=your-x-client-secret
# optional; defaults to: tweet.read users.read offline.access
OAUTH_X_SCOPES=tweet.read users.read offline.access

OAUTH_ALLOWED_REDIRECT_URIS=norviqa://oauth/callback,norviqa://oauth/broker-callback,http://localhost:6969/auth/oauth/google/callback,http://localhost:6969/auth/oauth/apple/callback,http://localhost:6969/settings/integrations/ibkr/callback
```

Notes:

- Apple requires all 4 vars: `OAUTH_APPLE_CLIENT_ID`, `OAUTH_APPLE_TEAM_ID`, `OAUTH_APPLE_KEY_ID`, `OAUTH_APPLE_PRIVATE_KEY`.
- Google native (iOS) sign-in uses `OAUTH_GOOGLE_CLIENT_ID` (iOS client, custom-scheme redirect, no secret).
- Google **browser** sign-in requires a separate **Web application** client: `OAUTH_GOOGLE_WEB_CLIENT_ID` + `OAUTH_GOOGLE_WEB_CLIENT_SECRET`. iOS-type clients cannot register `https` redirect URIs, so the web flow fails if it reuses the iOS client. The backend automatically selects the web client for `http(s)` redirect URIs and the iOS client for custom-scheme redirects.
- X requires `OAUTH_X_CLIENT_ID` (`OAUTH_X_CLIENT_SECRET` optional depending on app type).
- `OAUTH_ALLOWED_REDIRECT_URIS` is a comma-separated allowlist. The redirect URI sent by the client must match one of these values exactly.
- iOS IBKR broker connect sends `norviqa://oauth/broker-callback`; include it in `OAUTH_ALLOWED_REDIRECT_URIS` or connect/start returns `Broker redirect URI is not allowed.`
- X may not return user email depending on app permissions. In that case backend creates a synthetic internal email for the OAuth account.

## StockPlanWeb (browser) redirect URIs

StockPlanWeb builds callbacks from `PUBLIC_BASE_URL`:

| Provider | Callback path |
|----------|---------------|
| Google | `{PUBLIC_BASE_URL}/auth/oauth/google/callback` |
| Apple | `{PUBLIC_BASE_URL}/auth/oauth/apple/callback` |
| IBKR broker connect | `{PUBLIC_BASE_URL}/settings/integrations/ibkr/callback` |

Local examples:

- `http://localhost:6969/auth/oauth/google/callback`
- `http://localhost:6969/auth/oauth/apple/callback`
- `http://localhost:6969/settings/integrations/ibkr/callback`
- `http://localhost:7000/...` if using StockPlanWeb docker-compose (port 7000)

Add every callback URL to **both** `OAUTH_ALLOWED_REDIRECT_URIS` and the provider console (below).

StockPlanWeb itself does **not** need Google/Apple secrets — only `BACKEND_URL`, `PUBLIC_BASE_URL`, `SESSION_SECRET`, and `COOKIE_SECURE` (see StockPlanWeb `.env.example`).

## Security hardening now enforced

The backend now performs strict `id_token` verification for Apple and Google:

- Signature must verify against provider JWKS.
- JWT header must include `kid`.
- JWT header `alg` must be `RS256`.
- JWT headers with embedded/dynamic key material (`jku`, `jwk`, `x5u`, `x5c`, `x5t`, `x5t#S256`, `crit`) are rejected.
- Standard OIDC claim checks are enforced (`iss`, `aud`, `exp`, `iat`, `nonce`, `sub`).

Operational requirement:

- Backend runtime must have outbound HTTPS access to:
  - `https://appleid.apple.com/auth/keys`
  - `https://www.googleapis.com/oauth2/v3/certs`

## Provider console configuration (Apple)

In [Apple Developer](https://developer.apple.com/account/resources/identifiers/list/serviceId) (Certificates, IDs & Profiles):

1. Create/use a **Services ID** as your `OAUTH_APPLE_CLIENT_ID` (e.g. `facorreia.financeplan.signin`).
2. Enable **Sign in with Apple** for that Services ID.
3. Register **Return URLs** (exact match):
   - iOS bridge: `https://api.yourdomain.com/v1/auth/oauth/apple/callback`
   - Web local: `http://localhost:6969/auth/oauth/apple/callback` (and `:7000` if using docker-compose)
   - Web prod: `https://app.yourdomain.com/auth/oauth/apple/callback`
4. Create a Sign in with Apple key and store:
   - Team ID → `OAUTH_APPLE_TEAM_ID`
   - Key ID → `OAUTH_APPLE_KEY_ID`
   - Private key PEM → `OAUTH_APPLE_PRIVATE_KEY` (single-line with `\n` or properly quoted multiline)

Apple POSTs results with `response_mode=form_post`. StockPlanWeb handles this via `POST /auth/oauth/apple/callback`.

## Provider console configuration (Google)

In [Google Cloud Console](https://console.cloud.google.com/apis/credentials) → OAuth 2.0 Client IDs:

1. Create a **Web application** client for browser sign-in (this is distinct from the iOS client).
2. Add **Authorized redirect URIs** on the Web application client:
   - Web local: `http://localhost:6969/auth/oauth/google/callback`
   - Web prod: `https://www.norviq.org/auth/oauth/google/callback`
3. iOS uses the separate **iOS** OAuth client with redirect `com.googleusercontent.apps.<ios-client-id-prefix>:/oauth2redirect`. Include it in `OAUTH_ALLOWED_REDIRECT_URIS`.
4. Map env vars:
   - iOS client → `OAUTH_GOOGLE_CLIENT_ID` (secret optional / empty)
   - Web application client → `OAUTH_GOOGLE_WEB_CLIENT_ID` + `OAUTH_GOOGLE_WEB_CLIENT_SECRET`
5. Ensure scopes support OpenID profile/email (backend requests `openid email profile`).

## Provider console configuration (X)

In X Developer Portal:

1. Configure OAuth 2.0 (Authorization Code with PKCE).
2. Register callback URI:
   - `norviqa://oauth/callback` (iOS)
   - Or HTTPS bridge: `https://api.yourdomain.com/v1/auth/oauth/x/callback`
3. Set client ID (`OAUTH_X_CLIENT_ID`), and client secret if confidential client (`OAUTH_X_CLIENT_SECRET`).
4. Ensure scopes include at least:
   - `tweet.read`
   - `users.read`
   - `offline.access` (if refresh support is needed later)

## Provider console configuration (IBKR Web API OAuth2)

IBKR broker connect supports two backend modes:

- `IBKR_CONNECT_MODE=gateway`: existing Client Portal Gateway flow. The app callback URI still must be allowlisted.
- `IBKR_CONNECT_MODE=oauth2`: IBKR Web API OAuth2 with `private_key_jwt`. The backend redirects users to IBKR and stores the returned access/refresh tokens on `broker_connections`.

OAuth2 backend env:

```env
IBKR_CONNECT_MODE=oauth2
IBKR_OAUTH_CLIENT_ID=your-ibkr-client-id
IBKR_OAUTH_KEY_ID=your-ibkr-key-id
IBKR_OAUTH_PRIVATE_KEY_PEM="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
IBKR_OAUTH_AUTHORIZATION_URL=https://...
IBKR_OAUTH_TOKEN_URL=https://...
IBKR_OAUTH_API_BASE_URL=https://...
IBKR_OAUTH_SCOPE=portfolio.read
```

Register this backend callback with IBKR exactly:

- `https://api.yourdomain.com/v1/auth/brokers/ibkr/callback`

Do not register the iOS custom scheme with IBKR. iOS receives the final result through the backend redirect to `norviqa://oauth/broker-callback`.

## Client/backend alignment requirements

- The iOS callback scheme must match the redirect URI scheme (`norviqa`) or Google reversed client ID.
- The redirect URI used by each client must be exactly the same value configured in:
  - Google OAuth client **Authorized redirect URIs**
  - Apple Services ID **Return URLs**
  - IBKR OAuth app callback URLs
  - `OAUTH_ALLOWED_REDIRECT_URIS` on backend

## WebAuthn / Passkeys

**Full runbook (local + production, troubleshooting, registration gap):** [`StockPlanWeb/docs/passkeys.md`](../../StockPlanWeb/docs/passkeys.md)

Optional backend env (see `.env.example`):

```env
WEBAUTHN_RP_ID=localhost
WEBAUTHN_RP_NAME=Norviq
WEBAUTHN_ORIGINS=http://localhost:6969,http://localhost:7000
```

- `WEBAUTHN_RP_ID`: registrable domain (`localhost` for local dev; `yourdomain.com` in prod — no `www` prefix if using apex).
- `WEBAUTHN_ORIGINS`: comma-separated origins that may initiate ceremonies (must match browser URL, including scheme and port).
- When unset, passkey login endpoints return 503 and StockPlanWeb shows “not enabled”.

Endpoints (proxied by StockPlanWeb BFF):

- `POST /v1/auth/webauthn/login/options`
- `POST /v1/auth/webauthn/login/verify`

## Startup behavior

- If Google OAuth env variables are missing, backend startup continues, but Google OAuth is disabled and the server logs a warning.
- If Apple or X env variables are missing, backend startup continues, but that provider is disabled and logged.
- OAuth routes still exist, but disabled provider start/exchange requests fail with provider-not-configured.
- If WebAuthn env is incomplete, passkey routes return 503.
