#!/usr/bin/env bash
# Deliberate, visible reboot step for enabling logical replication.
#
# rds.logical_replication is a static parameter: it only takes effect after the
# instance reboots. Terraform never does this. By default this script only
# REPORTS whether a reboot is pending; it reboots only with --confirm.
#
# Usage:
#   scripts/reboot.sh --identifier my-db [--identifier my-db-reader] [--region eu-central-1]
#   scripts/reboot.sh --identifier my-db --confirm [--wait]
#
# For Aurora, pass each DB instance identifier (not the cluster identifier).
# The Aurora path has not been exercised end to end - check the output carefully.

set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
confirm=false
wait=false
ids=()

while (($#)); do
  case "$1" in
    --identifier) ids+=("${2:?--identifier needs a value}"); shift 2 ;;
    --region) region="${2:?--region needs a value}"; shift 2 ;;
    --confirm) confirm=true; shift ;;
    --wait) wait=true; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

((${#ids[@]})) || { echo "at least one --identifier is required" >&2; exit 2; }
[[ -n $region ]] || { echo "set --region or AWS_REGION" >&2; exit 2; }

for id in "${ids[@]}"; do
  [[ $id =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] || { echo "invalid identifier: $id" >&2; exit 2; }
done

status() {
  aws rds describe-db-instances --region "$region" --db-instance-identifier "$1" \
    --query 'DBInstances[0].[DBInstanceStatus, DBParameterGroups[0].DBParameterGroupName, DBParameterGroups[0].ParameterApplyStatus]' \
    --output text
}

echo "Current state (status / parameter group / apply status):"
for id in "${ids[@]}"; do
  printf '  %s: %s\n' "$id" "$(status "$id")"
done
echo "'pending-reboot' means the new parameters are waiting for a reboot."

if ! $confirm; then
  echo
  echo "Dry run only. Re-run with --confirm to reboot. This causes a brief outage."
  exit 0
fi

for id in "${ids[@]}"; do
  echo "Rebooting $id ..."
  aws rds reboot-db-instance --region "$region" --db-instance-identifier "$id" >/dev/null
done

if $wait; then
  for id in "${ids[@]}"; do
    aws rds wait db-instance-available --region "$region" --db-instance-identifier "$id"
    printf '  %s: %s\n' "$id" "$(status "$id")"
  done
fi

echo "Done. Confirm with: SHOW wal_level;  (expect 'logical'), then re-apply with enable_postgres_objects = true."
