#!/usr/bin/env bash
# The deliberate, visible, approved reboot step for enabling logical replication.
#
# rds.logical_replication is a static parameter: it only takes effect after the
# parameter group is ATTACHED to the instance and the instance REBOOTS. Terraform
# never does this. This script:
#
#   - by default only REPORTS state and whether each instance is eligible;
#   - reboots only with --confirm, and then only if EVERY instance is
#       * 'available',
#       * attached to the expected parameter group (--parameter-group), and
#       * showing 'pending-reboot' (so the reboot is actually needed);
#   - requires --approved-by, and prints an audit line, so who approved it is on record.
#
# Usage:
#   scripts/reboot.sh --identifier my-db --region eu-central-1 [--parameter-group NAME]
#   scripts/reboot.sh --identifier my-db --region eu-central-1 \
#       --parameter-group NAME --approved-by "Jane Doe / CHG-1234" --confirm [--wait]
#
# --parameter-group is the module's `parameter_group_name` output.
# RDS for PostgreSQL instances only. Aurora (cluster parameter groups) is not supported.
# A reboot causes a brief outage (longer failover handling on Multi-AZ) - schedule it.

set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
expected_group=""
approved_by=""
confirm=false
wait=false
ids=()

while (($#)); do
  case "$1" in
    --identifier) ids+=("${2:?--identifier needs a value}"); shift 2 ;;
    --region) region="${2:?--region needs a value}"; shift 2 ;;
    --parameter-group) expected_group="${2:?--parameter-group needs a value}"; shift 2 ;;
    --approved-by) approved_by="${2:?--approved-by needs a value}"; shift 2 ;;
    --confirm) confirm=true; shift ;;
    --wait) wait=true; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

((${#ids[@]})) || { echo "at least one --identifier is required" >&2; exit 2; }
[[ -n $region ]] || { echo "set --region or AWS_REGION" >&2; exit 2; }

for id in "${ids[@]}"; do
  [[ $id =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] || { echo "invalid identifier: $id" >&2; exit 2; }
done

if $confirm; then
  [[ -n $expected_group ]] || { echo "--confirm requires --parameter-group (the group that must be attached)" >&2; exit 2; }
  [[ -n $approved_by ]] || { echo "--confirm requires --approved-by \"name / ticket\"" >&2; exit 2; }
fi

# prints: <instance status> <attached parameter group> <apply status> <multi-az>
status() {
  aws rds describe-db-instances --region "$region" --db-instance-identifier "$1" \
    --query 'DBInstances[0].[DBInstanceStatus, DBParameterGroups[0].DBParameterGroupName, DBParameterGroups[0].ParameterApplyStatus, MultiAZ]' \
    --output text
}

eligible=true
printf '%-28s %-12s %-36s %-16s %s\n' "INSTANCE" "STATUS" "PARAMETER GROUP" "APPLY STATUS" "MULTI-AZ"
for id in "${ids[@]}"; do
  read -r st grp apply maz <<<"$(status "$id")"
  printf '%-28s %-12s %-36s %-16s %s\n' "$id" "$st" "$grp" "$apply" "$maz"

  reasons=()
  [[ $st == "available" ]] || reasons+=("instance status is '$st', not 'available'")
  if [[ -n $expected_group && $grp != "$expected_group" ]]; then
    reasons+=("attached group is '$grp', expected '$expected_group' - attach it first; rebooting now would change nothing")
  fi
  [[ $apply == "pending-reboot" ]] || reasons+=("apply status is '$apply', not 'pending-reboot' - no reboot is needed (or the group is not attached)")

  if ((${#reasons[@]})); then
    eligible=false
    for r in "${reasons[@]}"; do printf '    NOT ELIGIBLE: %s\n' "$r"; done
  else
    printf '    eligible for reboot\n'
  fi
done

if ! $confirm; then
  echo
  echo "Report only - nothing was rebooted. To reboot, re-run with --parameter-group, --approved-by and --confirm."
  exit 0
fi

if ! $eligible; then
  echo
  echo "Refusing to reboot: at least one instance is not eligible (see above). Nothing was rebooted." >&2
  exit 1
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for id in "${ids[@]}"; do
  echo "AUDIT $now reboot of $id (region $region) approved by: $approved_by"
  aws rds reboot-db-instance --region "$region" --db-instance-identifier "$id" >/dev/null
done

if $wait; then
  for id in "${ids[@]}"; do
    aws rds wait db-instance-available --region "$region" --db-instance-identifier "$id"
    read -r st grp apply maz <<<"$(status "$id")"
    printf '  %s: %s / %s / %s\n' "$id" "$st" "$grp" "$apply"
  done
fi

echo "Done. Confirm with: SHOW wal_level;  (expect 'logical'), then run Phase 2 with enable_postgres_objects = true."
