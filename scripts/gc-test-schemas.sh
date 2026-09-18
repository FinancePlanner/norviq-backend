#!/usr/bin/env bash
#
# Sweep leaked `stockplan_test_<uuid>` schemas out of the development database.
#
# The suite now drops its own schema when the application shuts down
# (`TestSchemaTeardown` in Sources/StockPlanBackend/ConfigureBootstrap.swift),
# so anything this finds is residue: a run that was killed, crashed, or predates
# that teardown.
#
# Safety. A schema is only dropped when it can be *shown* to be nobody's:
#
#   1. Name. Only `stockplan_test_%`, and only names matching ^[a-z0-9_]+$.
#      `public` and the three system schemas can never match.
#   2. Age. Schemas created by the current code carry a COMMENT stamping their
#      birth time. A stamped schema is a candidate only once it is older than
#      --older-than (default 2 hours), so a suite running right now is never
#      touched.
#   3. Quiet database, for unstamped schemas. A schema created before the stamp
#      existed cannot be dated, so --include-unstamped additionally requires
#      that no other client is connected to this database at all. If a suite is
#      running, it holds connections, and the sweep refuses and names them.
#   4. Locks. Immediately before each drop, the schema is skipped if any other
#      backend holds a lock on a relation inside it.
#
# Each drop is its own statement, so an interrupted sweep leaves whole schemas
# either gone or untouched — never half-dropped — and re-running resumes.
#
# Dry run by default. Pass --apply to actually drop.

set -euo pipefail

APPLY=0
OLDER_THAN="2 hours"
LIMIT=500
INCLUDE_UNSTAMPED=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage: scripts/gc-test-schemas.sh [options]

  --apply                Actually drop. Without it, only report.
  --older-than <interval> Postgres interval, default "2 hours".
  --limit <n>            Most schemas to drop per run, default 500.
  --include-unstamped    Also sweep schemas with no birth stamp. Requires an
                         otherwise-idle database.
  -h, --help             This text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --older-than) OLDER_THAN="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --include-unstamped) INCLUDE_UNSTAMPED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"

env_value() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

PGHOST="${DATABASE_HOST:-$(env_value DATABASE_HOST)}"
PGPORT="${DATABASE_PORT:-$(env_value DATABASE_PORT)}"
PGUSER="${DATABASE_USERNAME:-$(env_value DATABASE_USERNAME)}"
PGDATABASE="${DATABASE_NAME:-$(env_value DATABASE_NAME)}"
PGPASSWORD="${DATABASE_PASSWORD:-$(env_value DATABASE_PASSWORD)}"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER PGDATABASE PGPASSWORD

psql_do() { psql -v ON_ERROR_STOP=1 -Atq -c "$1"; }

echo "database: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"

total=$(psql_do "select count(*) from pg_namespace where nspname like 'stockplan\_test\_%'")
echo "stockplan_test_% schemas present: $total"

# --- guard 3: is anything else connected? -----------------------------------
others=$(psql_do "
    select coalesce(string_agg(format('pid=%s %s', pid, coalesce(nullif(application_name, ''), backend_type)), ', '), '')
    from pg_stat_activity
    where datname = current_database()
      and pid <> pg_backend_pid()
      and backend_type = 'client backend'
")

if [ -n "$others" ]; then
    echo "other clients connected: $others"
else
    echo "other clients connected: none"
fi

# --- candidate selection ----------------------------------------------------
# `created=` comes from the COMMENT written in configurePersistence.
STAMPED_PREDICATE="
    nspname ~ '^[a-z0-9_]+\$'
    and nspname like 'stockplan\_test\_%'
    and substring(obj_description(oid, 'pg_namespace') from 'created=([^ ]+)') is not null
    and (substring(obj_description(oid, 'pg_namespace') from 'created=([^ ]+)'))::timestamptz
        < now() - interval '$OLDER_THAN'
"
UNSTAMPED_PREDICATE="
    nspname ~ '^[a-z0-9_]+\$'
    and nspname like 'stockplan\_test\_%'
    and substring(obj_description(oid, 'pg_namespace') from 'created=([^ ]+)') is null
"

PREDICATE="$STAMPED_PREDICATE"
if [ "$INCLUDE_UNSTAMPED" = 1 ]; then
    if [ -n "$others" ]; then
        echo
        echo "REFUSING --include-unstamped: this database has other clients." >&2
        echo "Unstamped schemas carry no birth time, so the only way to know they are" >&2
        echo "not in use is that nothing is using the database. Wait for the run above" >&2
        echo "to finish, or sweep only stamped schemas by dropping the flag." >&2
        exit 3
    fi
    PREDICATE="(($STAMPED_PREDICATE) or ($UNSTAMPED_PREDICATE))"
fi

# bash 3.2 (the one macOS ships) has no `mapfile`.
candidates=()
while IFS= read -r line; do
    [ -n "$line" ] && candidates+=("$line")
done < <(psql_do "
    select nspname from pg_namespace
    where $PREDICATE
    order by nspname
    limit $LIMIT
")

stamped_total=$(psql_do "select count(*) from pg_namespace where $STAMPED_PREDICATE")
unstamped_total=$(psql_do "select count(*) from pg_namespace where $UNSTAMPED_PREDICATE")
echo "stamped and older than '$OLDER_THAN': $stamped_total"
echo "unstamped (undatable, needs --include-unstamped on an idle database): $unstamped_total"
echo "selected this run (limit $LIMIT): ${#candidates[@]}"

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "nothing to do."
    exit 0
fi

if [ "$APPLY" != 1 ]; then
    echo
    echo "dry run; re-run with --apply to drop. First few:"
    printf '  %s\n' "${candidates[@]:0:5}"
    exit 0
fi

dropped=0
skipped=0
for schema in "${candidates[@]}"; do
    case "$schema" in
        stockplan_test_*) ;;
        *) echo "  refusing unexpected name: $schema" >&2; continue ;;
    esac

    # --- guard 4: someone is touching a table in there right now -------------
    busy=$(psql_do "
        select count(*) from pg_locks l
        join pg_class c on c.oid = l.relation
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = '$schema' and l.pid <> pg_backend_pid()
    ")
    if [ "$busy" != "0" ]; then
        echo "  skip (locked by another backend): $schema"
        skipped=$((skipped + 1))
        continue
    fi

    if psql_do "drop schema if exists \"$schema\" cascade" >/dev/null; then
        dropped=$((dropped + 1))
    else
        echo "  failed: $schema" >&2
        skipped=$((skipped + 1))
    fi
done

echo "dropped $dropped, skipped $skipped"
remaining=$(psql_do "select count(*) from pg_namespace where nspname like 'stockplan\_test\_%'")
echo "stockplan_test_% schemas remaining: $remaining"
[ "$remaining" -gt 0 ] && echo "re-run to continue (the sweep is idempotent)."
exit 0
