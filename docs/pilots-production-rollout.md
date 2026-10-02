# Pilot follows: turning it on in production

Pilot follows let a user follow a curated politician or 13F fund. Norviq mirrors that pilot's
trades as **simulated** trades into a hypothetical portfolio (Pro) or as a symbol feed into a
watchlist. No real orders are ever placed. Spec and plan:
`docs/superpowers/specs/2026-10-01-pilot-follow-design.md`,
`docs/superpowers/plans/2026-10-01-pilot-follow-backend.md`.

Written 2026-10-02. The feature is **on in staging and off in production**. This page is the
to-do for switching production on later.

## Where things stand

| Piece | State on 2026-10-02 |
|---|---|
| Backend | `main` 8550954: feature plus the staging gates. |
| Production api image | 715321f: feature **without** the staging gates. Must be promoted before enabling. |
| Staging api image | 8550954, `PILOTS_ENABLED: "true"` (infra #259). |
| Production flag | `PILOTS_ENABLED: "false"` in `apps/norviq/api/values-production.yaml` (infra #254). |
| Web, iOS, MCP | Merged and pushed. Pilot UI and tools hide or say "not enabled" while the backend answers 404. |
| Database | Production already ran `CreatePilotTables`, `SeedPilots`. `AddPilotFollowTargetIndexes` runs with the 8550954 deploy. |

## Decision: no paid FMP plan (2026-10-02)

Politician pilots read FMP's free `senate-latest` / `house-latest` feeds (25 newest rows,
page 0). Norviq's FMP key is the free tier, about 250 calls a day **shared with every other
feature**. On staging the quota was already gone when ingestion ran, so every politician got
HTTP 429 and stayed empty. Fund pilots use SEC EDGAR and OpenFIGI and are unaffected.

Fernando decided not to pay for FMP for now. Consequences, pick one before enabling:

1. **Launch funds-only (recommended).** Deactivate the politicians so nobody sees 13 pilots
   that say "No trades seen yet":

   ```sql
   UPDATE pilots SET active = false WHERE kind = 'politician';
   ```

   Re-activate with `active = true` once there is a working congress source. Inactive pilots
   are hidden from `/v1/pilots` and are never ingested.
2. **Launch as is.** Politicians appear but stay empty on any day the shared quota runs out
   first. Users see "No trades seen yet" and can't follow them.

Free ways to give politicians data later, none done yet: a separate free FMP key used only by
pilot ingestion (check FMP's terms on multiple free accounts first), or reading House/Senate
disclosures from the official sources directly.

## Before switching on

- [ ] Compliance read of the "follow X" wording in iOS, web and MCP copy.
- [ ] FMP data-display terms checked for showing disclosure data in the app.
- [ ] Choose option 1 or 2 above.
- [ ] Staging spot-check on 8550954 (the gates build): follow a fund into a new hypothetical
      portfolio, follow a fund into a new watchlist, unfollow then delete the portfolio,
      confirm a manual sell into a followed portfolio is refused with 409.
- [ ] On production, confirm no stray simulated accounts exist yet:
      `SELECT count(*) FROM accounts WHERE broker = 'pilot';` should be `0`.

## Switching on

1. **Promote the gates build.** In the infra repo, dispatch `promote-norviq.yml` with an
   explicit service (it defaults to `api`):

   ```bash
   gh workflow run promote-norviq.yml --repo LuminaVault/LuminaVaultInfra -f service=both
   ```

   Merge the "Promote Norviq to production" PR it opens. Confirm
   `apps/norviq/api/values-production.yaml` now pins 8550954 or later. The migration job runs
   `AddPilotFollowTargetIndexes` before the new pods start.
2. **If you chose option 1**, run the `UPDATE pilots … kind = 'politician'` statement on the
   production database now.
3. **Flip the flag.** In `apps/norviq/api/values-production.yaml` change

   ```yaml
     - name: PILOTS_ENABLED
       value: "false"
   ```

   to `value: "true"`, open a PR and merge it. ArgoCD rolls the api pods. Do not touch
   `values-common.yaml`; production's env list overrides it.
4. **Verify.**
   - `kubectl -n norviq exec deploy/api -- printenv PILOTS_ENABLED` prints `true`.
   - About 4 minutes after the pods start, the api log shows `pilot_ingestion new_version`
     for the funds.
   - `GET /v1/pilots` returns the active pilots; the web pilots page and the iOS
     "Follow a pilot" row appear.

## Turning it off again

Set `PILOTS_ENABLED` back to `"false"` in `values-production.yaml` and merge. Routes return
404, the jobs stop, and every client hides pilots. Existing follows, simulated portfolios and
watchlists stay in the database untouched.
