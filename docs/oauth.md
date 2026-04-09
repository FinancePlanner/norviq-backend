# OAuth Setup (Backend)

This document lists the minimum required configuration for OAuth to work end-to-end with the current backend implementation.

## Supported providers (current state)

- `apple` is implemented.
- `google` is implemented.
- `x` is implemented.

## Required environment variables

Set these variables on the backend runtime:

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

OAUTH_ALLOWED_REDIRECT_URIS=norviqa://oauth/callback
```

Notes:

- Apple requires all 4 vars: `OAUTH_APPLE_CLIENT_ID`, `OAUTH_APPLE_TEAM_ID`, `OAUTH_APPLE_KEY_ID`, `OAUTH_APPLE_PRIVATE_KEY`.
- Google requires `OAUTH_GOOGLE_CLIENT_ID` and `OAUTH_GOOGLE_CLIENT_SECRET`.
- X requires `OAUTH_X_CLIENT_ID` (`OAUTH_X_CLIENT_SECRET` optional depending on app type).
- `OAUTH_ALLOWED_REDIRECT_URIS` is a comma-separated allowlist. The redirect URI sent by the client must match one of these values exactly.
- X may not return user email depending on app permissions. In that case backend creates a synthetic internal email for the OAuth account.

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

In Apple Developer (Certificates, IDs & Profiles):

1. Create/use a **Services ID** as your `OAUTH_APPLE_CLIENT_ID`.
2. Enable **Sign in with Apple** for that Services ID.
3. Register redirect URI:
   - `norviqa://oauth/callback`
4. Create a Sign in with Apple key and store:
   - Team ID (`OAUTH_APPLE_TEAM_ID`)
   - Key ID (`OAUTH_APPLE_KEY_ID`)
   - Private key PEM (`OAUTH_APPLE_PRIVATE_KEY`)

## Provider console configuration (Google)

In Google Cloud Console (OAuth client settings):

1. Configure the app redirect URI exactly as:
   - `norviqa://oauth/callback`
2. Use the generated client ID/secret in backend env variables above.
3. Ensure scopes support OpenID profile/email (backend requests `openid email profile`).

## Provider console configuration (X)

In X Developer Portal:

1. Configure OAuth 2.0 (Authorization Code with PKCE).
2. Register callback URI:
   - `norviqa://oauth/callback`
3. Set client ID (`OAUTH_X_CLIENT_ID`), and client secret if confidential client (`OAUTH_X_CLIENT_SECRET`).
4. Ensure scopes include at least:
   - `tweet.read`
   - `users.read`
   - `offline.access` (if refresh support is needed later)

## Client/backend alignment requirements

- The iOS callback scheme must match the redirect URI scheme (`norviqa`).
- The redirect URI used by the client must be exactly the same value configured in:
  - Google OAuth client settings
  - `OAUTH_ALLOWED_REDIRECT_URIS` on backend

## Startup behavior

- If Google OAuth env variables are missing, backend startup continues, but Google OAuth is disabled and the server logs a warning.
- If Apple or X env variables are missing, backend startup continues, but that provider is disabled and logged.
- OAuth routes still exist, but disabled provider start/exchange requests fail with provider-not-configured.
