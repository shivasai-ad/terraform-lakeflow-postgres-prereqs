#!/usr/bin/env bash
# Verifies the CDC prerequisites on a PostgreSQL source after Phase 2.
# Read-only: runs catalog queries only. Exits non-zero if any check fails.
#
# Connection (standard libpq variables, admin or any role that can read the catalogs):
#   PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD [PGSSLMODE]
#
# Expected state (take these from the module's `expected_state` output):
#   REPL_USER              replication username
#   PUBLICATION            publication name
#   SLOT                   replication slot name
#   TABLES                 comma-separated schema-qualified published tables
#   PKLESS_TABLES          comma-separated tables that must have REPLICA IDENTITY FULL (optional)
#   USE_RDS_REPLICATION_ROLE  true (default) = check rds_replication membership,
#                             false = check the REPLICATION attribute
#   EXPECT_WAL_CAP_MB      expected max_slot_wal_keep_size in MB (optional)

set -uo pipefail

: "${REPL_USER:?REPL_USER is required}"
: "${PUBLICATION:?PUBLICATION is required}"
: "${SLOT:?SLOT is required}"
: "${TABLES:?TABLES is required}"
PKLESS_TABLES="${PKLESS_TABLES:-}"
USE_RDS_REPLICATION_ROLE="${USE_RDS_REPLICATION_ROLE:-true}"
EXPECT_WAL_CAP_MB="${EXPECT_WAL_CAP_MB:-}"

ident='^[A-Za-z_][A-Za-z0-9_]*$'
qualified='^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$'

[[ $REPL_USER =~ $ident ]] || { echo "invalid REPL_USER" >&2; exit 2; }
[[ $PUBLICATION =~ $ident ]] || { echo "invalid PUBLICATION" >&2; exit 2; }
[[ $SLOT =~ $ident ]] || { echo "invalid SLOT" >&2; exit 2; }

IFS=',' read -r -a tables <<<"$TABLES"
IFS=',' read -r -a pkless <<<"$PKLESS_TABLES"
for t in "${tables[@]}"; do
  [[ $t =~ $qualified ]] || { echo "invalid table in TABLES: $t" >&2; exit 2; }
done
for t in ${pkless[@]+"${pkless[@]}"}; do
  [[ -z $t ]] && continue
  [[ $t =~ $qualified ]] || { echo "invalid table in PKLESS_TABLES: $t" >&2; exit 2; }
done

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# q "<sql>" name=value ...  -> SQL is sent on stdin so :'name' interpolation is applied safely.
q() {
  local sql="$1"
  shift
  local args=()
  local kv
  for kv in "$@"; do args+=(-v "$kv"); done
  printf '%s\n' "$sql" | psql -X -qtAX -v ON_ERROR_STOP=1 ${args[@]+"${args[@]}"}
}

# 1. WAL level
wal_level="$(q 'SHOW wal_level;')"
[[ $wal_level == "logical" ]] && pass "wal_level = logical" || bad "wal_level is '$wal_level', expected 'logical' (parameter group attached and instance rebooted?)"

# 2. Replication user and privilege
exists="$(q "SELECT count(*) FROM pg_roles WHERE rolname = :'u' AND rolcanlogin;" "u=$REPL_USER")"
if [[ $exists == "1" ]]; then
  pass "user $REPL_USER exists and can log in"
  if [[ $USE_RDS_REPLICATION_ROLE == "true" ]]; then
    ok="$(q "SELECT pg_has_role(:'u', 'rds_replication', 'member');" "u=$REPL_USER")"
    [[ $ok == "t" ]] && pass "$REPL_USER is a member of rds_replication" || bad "$REPL_USER is not a member of rds_replication"
  else
    ok="$(q "SELECT rolreplication FROM pg_roles WHERE rolname = :'u';" "u=$REPL_USER")"
    [[ $ok == "t" ]] && pass "$REPL_USER has the REPLICATION attribute" || bad "$REPL_USER lacks the REPLICATION attribute"
  fi
else
  bad "user $REPL_USER does not exist or cannot log in"
fi

# 3. SELECT grant on every published table
for t in "${tables[@]}"; do
  ok="$(q "SELECT has_table_privilege(:'u', :'t'::regclass, 'SELECT');" "u=$REPL_USER" "t=$t" 2>/dev/null)"
  [[ $ok == "t" ]] && pass "$REPL_USER can SELECT $t" || bad "$REPL_USER cannot SELECT $t (or the table does not exist)"
done

# 4. Publication exists and contains every expected table
pub="$(q "SELECT count(*) FROM pg_publication WHERE pubname = :'p';" "p=$PUBLICATION")"
if [[ $pub == "1" ]]; then
  pass "publication $PUBLICATION exists"
  for t in "${tables[@]}"; do
    schema="${t%%.*}"
    table="${t##*.}"
    n="$(q "SELECT count(*) FROM pg_publication_tables WHERE pubname = :'p' AND schemaname = :'s' AND tablename = :'n';" "p=$PUBLICATION" "s=$schema" "n=$table")"
    [[ $n == "1" ]] && pass "publication contains $t" || bad "publication $PUBLICATION is missing $t"
  done
else
  bad "publication $PUBLICATION does not exist"
fi

# 5. Replication slot exists and uses pgoutput
plugin="$(q "SELECT plugin FROM pg_replication_slots WHERE slot_name = :'s';" "s=$SLOT")"
if [[ -z $plugin ]]; then
  bad "replication slot $SLOT does not exist"
elif [[ $plugin == "pgoutput" ]]; then
  pass "replication slot $SLOT exists (pgoutput)"
else
  bad "replication slot $SLOT uses plugin '$plugin', expected 'pgoutput'"
fi

# 6. REPLICA IDENTITY FULL on the declared PK-less tables
for t in ${pkless[@]+"${pkless[@]}"}; do
  [[ -z $t ]] && continue
  ri="$(q "SELECT relreplident FROM pg_class WHERE oid = :'t'::regclass;" "t=$t" 2>/dev/null)"
  [[ $ri == "f" ]] && pass "$t has REPLICA IDENTITY FULL" || bad "$t does not have REPLICA IDENTITY FULL (relreplident='$ri')"
done

# 7. Catch published tables with no primary key and no REPLICA IDENTITY FULL.
#    This is the failure mode behind "CDC not enabled" errors for newly added tables.
unprotected="$(q "
SELECT format('%I.%I', pt.schemaname, pt.tablename)
FROM pg_publication_tables pt
WHERE pt.pubname = :'p'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = format('%I.%I', pt.schemaname, pt.tablename)::regclass AND i.indisprimary)
  AND (SELECT relreplident FROM pg_class
       WHERE oid = format('%I.%I', pt.schemaname, pt.tablename)::regclass) <> 'f';" "p=$PUBLICATION")"
if [[ -z $unprotected ]]; then
  pass "no published table lacks both a primary key and REPLICA IDENTITY FULL"
else
  while IFS= read -r t; do
    bad "published table $t has no primary key and no REPLICA IDENTITY FULL"
  done <<<"$unprotected"
fi

# 8. WAL retention cap
cap="$(q "SELECT setting FROM pg_settings WHERE name = 'max_slot_wal_keep_size';")"
if [[ -n $EXPECT_WAL_CAP_MB ]]; then
  [[ $cap == "$EXPECT_WAL_CAP_MB" ]] && pass "max_slot_wal_keep_size = ${cap}MB" || bad "max_slot_wal_keep_size is '${cap}', expected ${EXPECT_WAL_CAP_MB}MB"
else
  echo "INFO  max_slot_wal_keep_size = ${cap} (-1 means unlimited)"
fi

echo
if ((fail == 0)); then
  echo "All checks passed."
else
  echo "$fail check(s) failed."
  exit 1
fi
