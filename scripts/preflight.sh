#!/usr/bin/env bash
# Run BEFORE terraform plan/apply, from the machine that will run Terraform (the
# self-hosted, VPC-connected runner). Read-only. Fails early, with a fix hint,
# on the things that otherwise surface as cryptic errors mid-apply:
#
#   - psql missing, database unreachable, login failing        (connectivity)
#   - admin cannot create a publication                        (database privilege)
#   - admin does not own / belong to the owner of a table      (table ownership)
#   - rds_replication role missing                             (RDS role)
#   - no free replication slot                                 (capacity)
#   - wal_level not logical yet                                (only fatal in PHASE=2)
#
# Connection (standard libpq variables): PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD [PGSSLMODE]
#
#   TABLES                     comma-separated schema-qualified tables to be published (required)
#   PHASE                      1 (default) or 2. In phase 2 wal_level must already be 'logical'.
#   USE_RDS_REPLICATION_ROLE   true (default) = check the rds_replication role exists

set -uo pipefail

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${TABLES:?TABLES is required}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
PGPORT="${PGPORT:-5432}"
export PGPORT
PHASE="${PHASE:-1}"
USE_RDS_REPLICATION_ROLE="${USE_RDS_REPLICATION_ROLE:-true}"

qualified='^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$'
[[ $PHASE == "1" || $PHASE == "2" ]] || { echo "PHASE must be 1 or 2" >&2; exit 2; }
IFS=',' read -r -a tables <<<"$TABLES"
for t in "${tables[@]}"; do
  [[ $t =~ $qualified ]] || { echo "invalid table in TABLES: $t" >&2; exit 2; }
done

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
info() { printf 'INFO  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

q() {
  local sql="$1"
  shift
  local args=()
  local kv
  for kv in "$@"; do args+=(-v "$kv"); done
  printf '%s\n' "$sql" | psql -X -w -qtAX -v ON_ERROR_STOP=1 ${args[@]+"${args[@]}"}
}

# 1. Tooling
if command -v psql >/dev/null 2>&1; then
  pass "psql is installed ($(psql --version))"
else
  bad "psql is not installed on this machine - the REPLICA IDENTITY step needs it"
  echo "Cannot continue without psql."
  exit 1
fi

# 2. Network reachability (the runner must have a path to the private endpoint)
if command -v pg_isready >/dev/null 2>&1; then
  if pg_isready -q -h "$PGHOST" -p "$PGPORT" -t 5; then
    pass "database is reachable at $PGHOST:$PGPORT"
  else
    bad "cannot reach $PGHOST:$PGPORT - check this runner's network path, routing/DNS and the database security group (inbound $PGPORT from this runner)"
  fi
fi

# 3. Login
if ! who="$(q 'SELECT current_user;' 2>&1)"; then
  bad "cannot log in as $PGUSER: ${who//$'\n'/ }"
  echo
  echo "Cannot continue without a working login."
  exit 1
fi
pass "logged in as $who"

# 4. WAL level
wal="$(q 'SHOW wal_level;')"
if [[ $wal == "logical" ]]; then
  pass "wal_level = logical"
elif [[ $PHASE == "2" ]]; then
  bad "wal_level is '$wal' but Phase 2 needs 'logical' - attach the parameter group and reboot first (scripts/reboot.sh)"
else
  info "wal_level is '$wal' - expected before Phase 1; it must be 'logical' before Phase 2"
fi

# 5. Can create a publication
can_create="$(q "SELECT has_database_privilege(current_user, current_database(), 'CREATE');")"
if [[ $can_create == "t" ]]; then
  pass "$who has CREATE on database $PGDATABASE (needed for CREATE PUBLICATION)"
else
  bad "$who lacks CREATE on database $PGDATABASE - run: GRANT CREATE ON DATABASE $PGDATABASE TO $who;"
fi

# 6. Table existence and ownership (ALTER TABLE and publication membership both need it)
for t in "${tables[@]}"; do
  row="$(q "SELECT r.rolname || '|' || (pg_has_role(current_user, c.relowner, 'USAGE') OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user))::text FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE c.oid = :'t'::regclass;" "t=$t" 2>/dev/null)"
  if [[ -z $row ]]; then
    bad "table $t does not exist (or is not visible to $who)"
    continue
  fi
  owner="${row%%|*}"
  can="${row##*|}"
  if [[ $can == "true" ]]; then
    pass "$who can alter $t (owner: $owner)"
  else
    bad "$who does not own $t and is not a member of its owner '$owner' - run as a user who can: GRANT $owner TO $who;"
  fi
done

# 7. rds_replication role
if [[ $USE_RDS_REPLICATION_ROLE == "true" ]]; then
  has_role="$(q "SELECT count(*) FROM pg_roles WHERE rolname = 'rds_replication';")"
  if [[ $has_role == "1" ]]; then
    pass "role rds_replication exists"
  else
    bad "role rds_replication does not exist - is this RDS? (set use_rds_replication_role = false for self-managed Postgres)"
  fi
fi

# 8. Replication slot capacity
free="$(q "SELECT current_setting('max_replication_slots')::int - count(*) FROM pg_replication_slots;")"
if [[ $free =~ ^-?[0-9]+$ ]] && ((free >= 1)); then
  pass "$free replication slot(s) free"
else
  bad "no free replication slot (max_replication_slots reached) - increase it in the parameter group (needs a reboot) or drop an unused slot"
fi
info "max_wal_senders = $(q 'SHOW max_wal_senders;')"

echo
if ((fail == 0)); then
  echo "Preflight passed."
else
  echo "$fail check(s) failed."
  exit 1
fi
