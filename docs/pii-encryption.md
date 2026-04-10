# User PII Encryption (Phase 3)

This backend now supports field-level encryption at rest for selected `users` fields:

- `date_of_birth`
- `bio`
- `household_partner_display_name`

Encryption is AES-GCM with random nonce per write, and versioned envelopes carrying a key id.

## Required Environment Variables

For production, these are required at boot:

- `USER_PII_ENCRYPTION_ACTIVE_KEY_ID`
- `USER_PII_ENCRYPTION_ACTIVE_KEY`

`USER_PII_ENCRYPTION_ACTIVE_KEY` must be base64 for exactly 32 raw bytes.

Optional (for key rotation/decrypting legacy encrypted rows):

- `USER_PII_ENCRYPTION_PREVIOUS_KEYS`

Format:

`kid1:base64Key1,kid2:base64Key2`

## Startup Behavior

- Production: app boot fails fast if required key config is missing or malformed.
- Non-production: app falls back to an internal dev key when env vars are absent.

## Migration Rollout

Registered migrations in this phase:

1. `AddEncryptedUserProfileFields`
2. `BackfillEncryptedUserProfileFields`

Also included but intentionally not registered yet:

- `DropLegacyPlaintextUserProfileFields`

Keep plaintext columns until all environments have completed encrypted backfill and runtime behavior is stable. Register the drop migration only in the final cleanup phase.

## Logging

Do not log decrypted values or encrypted payloads.
