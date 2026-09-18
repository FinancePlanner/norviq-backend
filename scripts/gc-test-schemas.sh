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
BATCH=25
INCLUDE_UNSTAMPED=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage: scripts/gc-test-schemas.sh [options]

  --apply                Actually drop. Without it, only report.
  --older-than <interval> Postgres interval, default "2 hours".
  --limit <n>            Most schemas to drop per run, default 500.
  --batch-size <n>       Drops per psql invocation, default 25. Each DROP is
                         still its own transaction; this only bounds process
                         spawns. Do not raise it into "one big transaction" —
                         that hits max_locks_per_transaction and rolls back the
                         whole attempt.
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
        --batch-size) BATCH="$2"; shift 2 ;;
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

# Same precedence `configurePersistence` uses in the testing environment
# (ConfigureBootstrap.swift): TEST_DATABASE_* first, then DATABASE_*. They agree
# in the checked-in .env, but anyone who sets TEST_DATABASE_NAME would otherwise
# get a confident "0 schemas present" against a database that is not the one the
# suite writes to.
setting() {
    local test_key="TEST_$1" key="$1" value
    for value in "${!test_key-}" "$(env_value "$test_key")" "${!key-}" "$(env_value "$key")"; do
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done
}

PGHOST="$(setting DATABASE_HOST)"
PGPORT="$(setting DATABASE_PORT)"
PGUSER="$(setting DATABASE_USERNAME)"
PGDATABASE="$(setting DATABASE_NAME)"
PGPASSWORD="$(setting DATABASE_PASSWORD)"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER PGDATABASE PGPASSWORD

# Validate the two values that reach SQL, rather than trusting quoting alone.
case "$LIMIT" in
    ''|*[!0-9]*) echo "--limit must be a positive integer, got: $LIMIT" >&2; exit 2 ;;
esac
case "$BATCH" in
    ''|*[!0-9]*) echo "--batch-size must be a positive integer, got: $BATCH" >&2; exit 2 ;;
esac
case "$OLDER_THAN" in
    *[\'\\\;]*) echo "--older-than must be a plain Postgres interval, got: $OLDER_THAN" >&2; exit 2 ;;
esac

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
    select nspname || '|' ||
           coalesce(substring(obj_description(oid, 'pg_namespace') from 'pid=([0-9]+)'), '')
    from pg_namespace
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
    for entry in "${candidates[@]:0:5}"; do
        printf '  %s\n' "${entry%%|*}"
    done
    exit 0
fi

# --- guard 4: schemas some other backend is holding a relation lock in -------
# One query for the whole set. This guard is weaker than it looks: Fluent
# autocommits, so a live suite sitting between two queries holds no relation
# lock at all. It catches a backend mid-statement and nothing more, which is why
# guard 5 below exists.
locked_list=$(psql_do "
    select coalesce(string_agg(distinct n.nspname, ' '), '')
    from pg_locks l
    join pg_class c on c.oid = l.relation
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname like 'stockplan\_test\_%' and l.pid <> pg_backend_pid()
")

is_locked() {
    case " $locked_list " in (*" $1 "*) return 0 ;; esac
    return 1
}

dropped=0
skipped=0
batch_file="$(mktemp -t norviq-gc)"
trap 'rm -f "$batch_file"' EXIT
batch_names=()

flush_batch() {
    [ "${#batch_names[@]}" -eq 0 ] && return 0
    # `psql -f` without ON_ERROR_STOP runs each statement in its own implicit
    # transaction and keeps going after a failure. That matters: one DROP SCHEMA
    # CASCADE takes a lock per object in the schema, and a few hundred schemas
    # in a single transaction exhausts max_locks_per_transaction and rolls the
    # entire attempt back. Small batches, one transaction per schema.
    if psql -Atq -f "$batch_file" >/dev/null 2>&1; then
        dropped=$((dropped + ${#batch_names[@]}))
    else
        # Per-statement failures do not abort the file, so re-check what is left
        # rather than assuming the whole batch failed.
        local still
        still=$(psql_do "
            select count(*) from pg_namespace
            where nspname = any (string_to_array('$(printf '%s,' "${batch_names[@]}" | sed 's/,$//')', ','))
        ")
        dropped=$((dropped + ${#batch_names[@]} - still))
        skipped=$((skipped + still))
        echo "  $still of ${#batch_names[@]} in this batch did not drop" >&2
    fi
    : > "$batch_file"
    batch_names=()
}

for entry in "${candidates[@]}"; do
    schema="${entry%%|*}"
    owner_pid="${entry#*|}"
    [ "$owner_pid" = "$schema" ] && owner_pid=""

    case "$schema" in
        stockplan_test_*) ;;
        *) echo "  refusing unexpected name: $schema" >&2; skipped=$((skipped + 1)); continue ;;
    esac

    if is_locked "$schema"; then
        echo "  skip (locked by another backend): $schema"
        skipped=$((skipped + 1))
        continue
    fi

    # --- guard 5: the process that created it is still alive -----------------
    # The stamp records the test process's pid, and `kill -0` asks about a pid
    # on *this* host. It is only a true owner check when the sweep runs where
    # the suite ran, which is the normal case here.
    #
    # Run it elsewhere — or against a schema old enough for its pid to have been
    # recycled — and the number matches some unrelated local process instead.
    # That is a false positive, not a miss: the schema is skipped when it could
    # have been dropped. Over-skipping is the safe direction and re-running
    # after the imposter exits collects it, so this stays a skip rather than
    # something cleverer. It is never a reason to drop a schema.
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        echo "  skip (creating process $owner_pid still alive): $schema"
        skipped=$((skipped + 1))
        continue
    fi

    printf 'drop schema if exists "%s" cascade;\n' "$schema" >> "$batch_file"
    batch_names+=("$schema")
    [ "${#batch_names[@]}" -ge "$BATCH" ] && flush_batch
done
flush_batch

echo "dropped $dropped, skipped $skipped"
remaining=$(psql_do "select count(*) from pg_namespace where nspname like 'stockplan\_test\_%'")
echo "stockplan_test_% schemas remaining: $remaining"
[ "$remaining" -gt 0 ] && echo "re-run to continue (the sweep is idempotent)."
exit 0
