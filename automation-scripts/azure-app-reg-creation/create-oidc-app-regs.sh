#!/usr/bin/env bash
# DO-1382 — create Entra ID app registrations for the Azure OIDC approach.
# One registration per service, named <service>-oidc-azure, plus its service
# principal (required for Azure RBAC role assignment). Idempotent: an existing
# display name is reused (EXISTS), and a missing SP is added even for reused apps.
#
# Services are inputs: positional args, or one per line in services.conf
# ('#' comments and blank lines allowed; --services FILE for another path,
# --services - reads stdin). "-oidc-azure" is appended to each name.
#
# DRY-RUN by default; --apply creates. Progress goes to stderr, the TSV report
# (DISPLAY_NAME  CLIENT_ID  STATUS) to stdout:
#   ./create-oidc-app-regs.sh                                   # preview services.conf
#   ./create-oidc-app-regs.sh --apply > oidc-app-registrations.tsv
#   ./create-oidc-app-regs.sh --apply skynet-client skygate-backend   # ad hoc subset
# Prereqs: az CLI, logged in (az login), permission to create app registrations
# (Application Developer role, or Application.ReadWrite.All).
# No 'set -e': failures are counted and the run continues; exit 1 if any occurred.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0
SUFFIX="-oidc-azure"
SERVICES_FILE="$DIR/services.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --services) SERVICES_FILE="${2:?missing value for --services}"; shift 2 ;;
    -h|--help) echo "Usage: $(basename "$0") [--apply] [--services FILE|-] [service ...]"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ $# -gt 0 ]]; then
  SERVICES=("$@")
else
  [[ "$SERVICES_FILE" == "-" || -f "$SERVICES_FILE" ]] \
    || { echo "ERROR: no services given and ${SERVICES_FILE} not found." >&2; exit 1; }
  SERVICES=()
  while IFS= read -r s; do SERVICES+=("$s"); done \
    < <(grep -vE '^[[:space:]]*(#|$)' "$SERVICES_FILE" | awk '{print $1}')
  [[ ${#SERVICES[@]} -gt 0 ]] || { echo "ERROR: no services in ${SERVICES_FILE}." >&2; exit 1; }
fi

command -v az >/dev/null || { echo "ERROR: az CLI not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged in. Run 'az login' first." >&2; exit 1; }

echo "Tenant: $(az account show --query tenantId -o tsv)" >&2
[[ $APPLY -eq 1 ]] && echo "MODE: APPLY — app registrations will be created." >&2 \
                   || echo "MODE: DRY RUN — nothing will be created. Re-run with --apply." >&2

errors=0
fail() { echo "    x $1" >&2; errors=$((errors+1)); }

printf 'DISPLAY_NAME\tCLIENT_ID\tSTATUS\n'

for svc in "${SERVICES[@]}"; do
  name="${svc}${SUFFIX}"
  echo "--- ${name}" >&2

  existing="$(az ad app list --all --filter "displayName eq '${name}'" \
                --query "[0].appId" -o tsv 2>/dev/null)" || existing=""
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    # Reused app may still be missing its SP — ensure it exists.
    if [[ $APPLY -eq 1 ]] && ! az ad sp show --id "$existing" >/dev/null 2>&1; then
      az ad sp create --id "$existing" >/dev/null 2>&1 \
        && echo "    + service principal added to existing app" >&2 \
        || fail "${name}: could not create service principal for existing app"
    fi
    printf '%s\t%s\t%s\n' "$name" "$existing" "EXISTS"
    continue
  fi

  if [[ $APPLY -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "$name" "-" "WOULD_CREATE"
    continue
  fi

  if ! app_id="$(az ad app create --display-name "$name" \
                   --sign-in-audience AzureADMyOrg --query appId -o tsv 2>&1)" \
     || [[ -z "$app_id" || "$app_id" == "None" ]]; then
    fail "${name}: app create failed: ${app_id//$'\n'/ }"
    printf '%s\t%s\t%s\n' "$name" "-" "FAILED"
    continue
  fi

  if az ad sp create --id "$app_id" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\n' "$name" "$app_id" "CREATED"
  else
    fail "${name}: app created but service principal failed (retry: az ad sp create --id ${app_id})"
    printf '%s\t%s\t%s\n' "$name" "$app_id" "CREATED_NO_SP"
  fi
done

{
  echo
  echo "Next steps (not done by this script):"
  echo "  1. Add a federated identity credential per app for your CI provider:"
  echo "       az ad app federated-credential create --id <APP_ID> --parameters '{"
  echo "         \"name\": \"github-main\","
  echo "         \"issuer\": \"https://token.actions.githubusercontent.com\","
  echo "         \"subject\": \"repo:<ORG>/<REPO>:ref:refs/heads/main\","
  echo "         \"audiences\": [\"api://AzureADTokenExchange\"]"
  echo "       }'"
  echo "  2. Assign the needed Azure RBAC role to each service principal."
  echo "  3. Store each client ID in the corresponding pipeline as AZURE_CLIENT_ID."
} >&2

[[ $errors -gt 0 ]] && { echo "==> Completed with ${errors} error(s) — see 'x' lines above." >&2; exit 1; }
exit 0
