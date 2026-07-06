# Runbook: restore drill (quarterly)

A backup that has never been restored does not exist. Calendar recurrence:
first weekend of Jan / Apr / Jul / Oct.

1. List and fetch the newest off-site dump (workstation):
   ```bash
   rclone lsl storagebox:backups/pg | sort -k2 | tail -3
   rclone copyto storagebox:backups/pg/<latest>.dump.age ./drill.dump.age
   age -d -i ~/keys/norviq-backup.agekey -o drill.dump ./drill.dump.age
   ```
2. Restore into a throwaway database in the cluster:
   ```bash
   kubectl -n data exec postgres-0 -- sh -c \
     'psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS drill; CREATE DATABASE drill;"'
   kubectl -n data exec -i postgres-0 -- sh -c \
     'pg_restore -U "$POSTGRES_USER" -d drill' < drill.dump
   ```
3. Sanity checks (row counts must be plausible, not zero):
   ```bash
   kubectl -n data exec postgres-0 -- sh -c \
     'psql -U "$POSTGRES_USER" -d drill -c "SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM subscriptions) AS subscriptions;"'
   ```
4. Clean up: `DROP DATABASE drill;`, delete local dump files.
5. Record in this repo (append below): date, dump used, restore duration, row
   counts, issues.

## Drill log

| Date | Dump | Duration | users / subscriptions | Notes |
|---|---|---|---|---|
