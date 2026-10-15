-- Pre-hijack squat candidates (READ-ONLY; run by hand, never from the app).
--
-- Before v1.4.1 a password account could be registered with someone else's
-- email, and the owner's later Google/Apple/X sign-in silently linked to it,
-- leaving the squatter's password and sessions in place. The v1.4.1 backfill
-- cannot tell those accounts apart, so it lists them for a human to review.
--
-- A candidate is an account whose FIRST OAuth identity arrived more than 60s
-- after the account was created (so the account began as a password sign-up)
-- and did not come through an explicit, signed-in link flow
-- (`oauth_flows.purpose = 'link'` for that user and provider, used within a
-- minute of the identity). Those arrived through the sign-in path, which is
-- the one that auto-linked by email.
--
-- Not proof of abuse: a real owner who registered with a password and later
-- tapped "Sign in with Google" looks the same. Review each one (login history,
-- sessions, recent email/password changes) before acting.
--
-- Run against production read-only, e.g.:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c 'SET TRANSACTION READ ONLY' -f docs/pre-hijack-squat-candidates.sql

WITH first_identity AS (
    SELECT DISTINCT ON (i.user_id)
        i.user_id,
        i.provider,
        i.email AS identity_email,
        i.email_verified,
        i.created_at AS linked_at
    FROM oauth_identities i
    ORDER BY i.user_id, i.created_at
)
SELECT
    u.id AS user_id,
    u.email,
    u.created_at AS account_created_at,
    fi.provider,
    fi.identity_email,
    fi.email_verified,
    fi.linked_at,
    fi.linked_at - u.created_at AS password_only_for,
    u.email_verified_at,
    u.password_set_at
FROM users u
JOIN first_identity fi ON fi.user_id = u.id
WHERE fi.linked_at > u.created_at + interval '60 seconds'
  AND NOT EXISTS (
      SELECT 1
      FROM oauth_flows f
      WHERE f.user_id = u.id
        AND f.purpose = 'link'
        AND f.provider = fi.provider
        AND f.used_at IS NOT NULL
        AND f.used_at BETWEEN fi.linked_at - interval '60 seconds' AND fi.linked_at + interval '60 seconds'
  )
ORDER BY fi.linked_at DESC;
