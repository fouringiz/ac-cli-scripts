#!/usr/bin/env bash
#
# set-org-runner-label.sh
#
# Scans every repository in a GitHub org for an Actions *repository variable*
# (default: RUNNER_LABEL). Where the variable exists, its value is replaced with
# the one you provide. Repos without the variable are left completely untouched —
# nothing is ever created.
#
# Dry-run by default. Pass --apply to actually write.
#
# Requires: gh (GitHub CLI, authenticated), jq is NOT needed (gh has --jq built in)
# Token scopes: repo + admin:org, or a fine-grained token with
#               "Variables: read and write" on the target repos.
#
set -euo pipefail

VAR_NAME="RUNNER_LABEL"
APPLY=0
INCLUDE_ARCHIVED=0
ORG=""
NEW_VALUE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --org ORG --value NEW_VALUE [options]

Required:
  --org ORG            GitHub organization (or user) login
  --value NEW_VALUE    New value for the variable

Options:
  --var-name NAME      Variable to look for (default: ${VAR_NAME})
  --apply              Actually perform the updates (default is dry-run)
  --include-archived   Also update archived repos (default: skipped)
  -h, --help           Show this help

Examples:
  $(basename "$0") --org acme --value ubuntu-22.04-large
  $(basename "$0") --org acme --value ubuntu-22.04-large --apply
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)              ORG="${2:?missing value for --org}"; shift 2 ;;
    --value)            NEW_VALUE="${2:?missing value for --value}"; shift 2 ;;
    --var-name)         VAR_NAME="${2:?missing value for --var-name}"; shift 2 ;;
    --apply)            APPLY=1; shift ;;
    --include-archived) INCLUDE_ARCHIVED=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ORG" && -n "$NEW_VALUE" ]] || { echo "ERROR: --org and --value are required." >&2; usage >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated. Run 'gh auth login'." >&2; exit 1; }

if [[ $APPLY -eq 1 ]]; then
  echo "MODE: APPLY — variables will be written."
else
  echo "MODE: DRY RUN — no changes will be made. Re-run with --apply to write."
fi
echo "Org: ${ORG}   Variable: ${VAR_NAME}   New value: ${NEW_VALUE}"
echo

# --- collect repos -----------------------------------------------------------
echo "Listing repositories..."
repos_tsv="$(gh api "/orgs/${ORG}/repos?per_page=100&type=all" --paginate \
              --jq '.[] | [.full_name, (.archived|tostring)] | @tsv' 2>/dev/null)" \
  || repos_tsv="$(gh api "/users/${ORG}/repos?per_page=100&type=all" --paginate \
                    --jq '.[] | [.full_name, (.archived|tostring)] | @tsv')"

total=0; found=0; updated=0; skipped_archived=0; unchanged=0; errors=0
declare -a error_lines=()

while IFS=$'\t' read -r repo archived; do
  [[ -n "$repo" ]] || continue
  total=$((total+1))

  if [[ "$archived" == "true" && $INCLUDE_ARCHIVED -eq 0 ]]; then
    skipped_archived=$((skipped_archived+1))
    continue
  fi

  # Does the variable exist on this repo? (404 => not present, leave alone)
  if ! current="$(gh api "/repos/${repo}/actions/variables/${VAR_NAME}" --jq '.value' 2>&1)"; then
    if [[ "$current" != *"HTTP 404"* ]]; then
      errors=$((errors+1))
      error_lines+=("${repo}: ${current//$'\n'/ }")
    fi
    continue
  fi

  found=$((found+1))

  if [[ "$current" == "$NEW_VALUE" ]]; then
    unchanged=$((unchanged+1))
    printf '  = %-60s already %s\n' "$repo" "$current"
    continue
  fi

  if [[ $APPLY -eq 1 ]]; then
    if err="$(gh api --method PATCH "/repos/${repo}/actions/variables/${VAR_NAME}" \
                -f "name=${VAR_NAME}" -f "value=${NEW_VALUE}" --silent 2>&1)"; then
      updated=$((updated+1))
      printf '  ✔ %-60s %s -> %s\n' "$repo" "$current" "$NEW_VALUE"
    else
      errors=$((errors+1))
      error_lines+=("${repo}: ${err//$'\n'/ }")
      printf '  ✘ %-60s update failed\n' "$repo"
    fi
  else
    updated=$((updated+1))
    printf '  ~ %-60s %s -> %s (would update)\n' "$repo" "$current" "$NEW_VALUE"
  fi
done <<< "$repos_tsv"

# --- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Repos scanned:            ${total}"
echo "Skipped (archived):       ${skipped_archived}"
echo "Had ${VAR_NAME}:  ${found}"
if [[ $APPLY -eq 1 ]]; then
  echo "Updated:                  ${updated}"
else
  echo "Would update:             ${updated}"
fi
echo "Already correct:          ${unchanged}"
echo "Errors:                   ${errors}"

if [[ ${#error_lines[@]} -gt 0 ]]; then
  echo
  echo "Error detail:"
  printf '  - %s\n' "${error_lines[@]}"
fi

[[ $errors -eq 0 ]] || exit 1
