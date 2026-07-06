# Runbook: rollback

## App rollback (normal path — auditable)

```bash
# find the offending tag-bump / promote commit
git log --oneline -5 -- apps/api/values-production.yaml
git revert <commit> && git push   # ArgoCD deploys the old tag
```

## App rollback (emergency — seconds)

```bash
kubectl -n production rollout undo deploy/api    # or deploy/web
```
Then still do the git revert — otherwise ArgoCD self-heal reapplies the bad tag
within minutes.

## Failed migration

The PreSync hook failed → sync failed → **old ReplicaSet is still serving**.
Nothing is down. Fix forward (new migration) or restore the pre-migration dump.

The dump sits on the node at `/data/backups` (hostPath mounted into the migrate
job, not the postgres pod). Stream it in from the node:

```bash
ssh root@<node> ls -t /data/backups | head           # newest pre-migrate-*.dump
ssh root@<node> cat /data/backups/<pre-migrate-...>.dump | \
  kubectl -n data exec -i postgres-0 -- sh -c \
  'pg_restore --clean --if-exists -U "$POSTGRES_USER" -d stockplan_production'
```

Then revert the tag-bump commit so the failing image stops retrying.

## Full DB restore from off-site

See [runbook-restore-drill.md](runbook-restore-drill.md) — same procedure,
target the real database instead of the throwaway one.
