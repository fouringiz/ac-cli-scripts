#!/usr/bin/env bash
# Bump retention for every event hub ("topic") in one Event Hubs namespace
# from 7 days (168h) to 90 days (2160h). Hubs with any other retention, or
# with cleanup policy Compact (retention hours don't apply there), are skipped.
#
# NOTE: >7 days retention requires a Premium or Dedicated tier namespace —
# on Standard the update is rejected by the API and shows up as FAILED.
#
# DRY-RUN by default; --apply writes. Progress goes to stderr, the TSV report
# (NAME  RETENTION_H  STATUS) to stdout:
#   ./bump-eventhub-retention.sh -g my-rg -n my-namespace
#   ./bump-eventhub-retention.sh -g my-rg -n my-namespace --apply > report.tsv
#
# Prereqs: az CLI, logged in, write access to the namespace.
# No 'set -e': failures are counted and the run continues; exit 1 if any occurred.

set -uo pipefail

APPLY=0 RG="" NS="" FROM_H=168 TO_H=2160

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RG="${2:?}"; shift 2 ;;
    -n|--namespace)      NS="${2:?}"; shift 2 ;;
    --from-hours)        FROM_H="${2:?}"; shift 2 ;;
    --to-hours)          TO_H="${2:?}"; shift 2 ;;
    --apply)             APPLY=1; shift ;;
    -h|--help) echo "Usage: $(basename "$0") -g RG -n NAMESPACE [--from-hours 168] [--to-hours 2160] [--apply]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$RG" && -n "$NS" ]] || { echo "ERROR: -g RESOURCE_GROUP and -n NAMESPACE are required." >&2; exit 2; }

command -v az >/dev/null || { echo "ERROR: az CLI not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged in. Run 'az login' first." >&2; exit 1; }

[[ $APPLY -eq 1 ]] && echo "MODE: APPLY — retention ${FROM_H}h hubs will be set to ${TO_H}h." >&2 \
                   || echo "MODE: DRY RUN — nothing will be changed. Re-run with --apply." >&2
echo "Namespace: ${NS} (rg ${RG})" >&2

# join with '|' and to_string nulls: bash collapses adjacent tabs, which would
# shift columns whenever az emits an empty field for a null property.
HUBS="$(az eventhubs eventhub list -g "$RG" --namespace-name "$NS" \
          --query "[].join('|',[name,to_string(retentionDescription.cleanupPolicy),to_string(retentionDescription.retentionTimeInHours),to_string(messageRetentionInDays)])" \
          -o tsv)" || { echo "ERROR: could not list event hubs in ${NS}." >&2; exit 1; }
[[ -n "$HUBS" ]] || { echo "ERROR: no event hubs found in ${NS}." >&2; exit 1; }

errors=0
printf 'NAME\tRETENTION_H\tSTATUS\n'

while IFS='|' read -r name policy hours days; do
  [[ -n "$name" ]] || continue
  # Older hubs may only carry messageRetentionInDays — fall back to days*24.
  if ! [[ "$hours" =~ ^[0-9]+$ ]]; then
    [[ "$days" =~ ^[0-9]+$ ]] && hours=$((days * 24)) || hours=0
  fi

  if [[ "$policy" == Compact* ]]; then
    printf '%s\t%s\t%s\n' "$name" "-" "SKIPPED_COMPACT"
  elif [[ "$hours" -ne "$FROM_H" ]]; then
    printf '%s\t%s\t%s\n' "$name" "$hours" "SKIPPED"
  elif [[ $APPLY -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "$name" "$hours" "WOULD_UPDATE"
  elif out="$(az eventhubs eventhub update -g "$RG" --namespace-name "$NS" \
                -n "$name" --retention-time-in-hours "$TO_H" 2>&1 >/dev/null)"; then
    printf '%s\t%s\t%s\n' "$name" "$TO_H" "UPDATED"
  else
    echo "    x ${name}: ${out//$'\n'/ }" >&2
    errors=$((errors+1))
    printf '%s\t%s\t%s\n' "$name" "$hours" "FAILED"
  fi
done <<< "$HUBS"

[[ $errors -gt 0 ]] && { echo "==> Completed with ${errors} error(s) — see 'x' lines above." >&2; exit 1; }
exit 0
