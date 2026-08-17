#!/usr/bin/env bash
# assign.sh
#
# Assign an Azure RBAC role on every storage account in a subscription whose
# name matches a glob pattern.
#
# Usage:
#   ./assign.sh <SUBSCRIPTION_ID> <TENANT_ID> <ROLE_NAME> <RESOURCE_PATTERN> <PRINCIPAL> [PRINCIPAL_TYPE]
#
# Args (all positional):
#   SUBSCRIPTION_ID   Azure subscription ID or display name
#   TENANT_ID         Entra tenant ID
#   ROLE_NAME         Built-in role name (e.g. 'Storage Blob Data Contributor') or role GUID
#   RESOURCE_PATTERN  Storage-account name glob, e.g. '*amanagementwebsite', 'dev*', '*sa*'
#                     ('*' and '?' supported; quote it to keep the shell off your back)
#   PRINCIPAL         Object ID / appId / display name / UPN of the assignee
#   PRINCIPAL_TYPE    Optional: User | Group | ServicePrincipal (default: ServicePrincipal)
#
# Example:
#   ./assign.sh 8640bde2-4e10-443a-b873-769f2204da02 \
#               <TENANT_ID> \
#               'Storage Blob Data Contributor' \
#               '*amanagementwebsite' \
#               asset-tracking-client-oidc-azure
#
# Behaviour:
#   - Scope: each matching storage account (least privilege).
#   - Idempotent: skips assignments that already exist.
#   - Prints a verification table at the end.
#
# Requires: az CLI, jq. `az login` must already be done.

set -euo pipefail

# ───────── inputs ─────────
if (( $# < 5 )); then
  sed -n '2,32p' "$0"
  exit 2
fi

SUBSCRIPTION_ID="$1"
TENANT_ID="$2"
ROLE_NAME="$3"
RESOURCE_PATTERN="$4"
PRINCIPAL="$5"
PRINCIPAL_TYPE="${6:-ServicePrincipal}"

case "$PRINCIPAL_TYPE" in
  User|Group|ServicePrincipal) ;;
  *) echo "ERROR: PRINCIPAL_TYPE must be User|Group|ServicePrincipal (got: $PRINCIPAL_TYPE)" >&2; exit 2 ;;
esac

# ───────── helpers ─────────
is_guid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# glob (*, ?) → anchored regex, escaping other regex metachars
glob_to_regex() {
  local g="$1" out="" i ch
  for (( i=0; i<${#g}; i++ )); do
    ch="${g:i:1}"
    case "$ch" in
      '*') out+='.*' ;;
      '?') out+='.'  ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'\'|'|') out+="\\$ch" ;;
      *)   out+="$ch" ;;
    esac
  done
  printf '^%s$' "$out"
}

# ───────── subscription ─────────
echo "→ az account set"
az account set --subscription "$SUBSCRIPTION_ID" --tenant "$TENANT_ID" 2>/dev/null \
  || az account set --subscription "$SUBSCRIPTION_ID"
SUB_ID="$(az account show --query id -o tsv)"
echo "  subscription: $SUB_ID"
echo "  tenant:       $TENANT_ID"

# ───────── resolve role ─────────
if is_guid "$ROLE_NAME"; then
  ROLE_ID="$ROLE_NAME"
  ROLE_DISPLAY="$(az role definition list --name "$ROLE_ID" --query '[0].roleName' -o tsv 2>/dev/null || echo "$ROLE_ID")"
else
  ROLE_ID="$(az role definition list --name "$ROLE_NAME" --query '[0].name' -o tsv)"
  ROLE_DISPLAY="$ROLE_NAME"
fi
if [[ -z "${ROLE_ID:-}" || "$ROLE_ID" == "null" ]]; then
  echo "ERROR: could not resolve role '$ROLE_NAME'" >&2
  exit 1
fi
echo "  role:         $ROLE_DISPLAY ($ROLE_ID)"

# ───────── resolve principal ─────────
resolve_principal() {
  local v="$1"
  case "$PRINCIPAL_TYPE" in
    User)
      if is_guid "$v"; then
        az ad user show --id "$v" --query id -o tsv 2>/dev/null || echo ""
      else
        az ad user show --id "$v" --query id -o tsv 2>/dev/null \
          || az ad user list --display-name "$v" --query '[0].id' -o tsv
      fi
      ;;
    Group)
      if is_guid "$v"; then
        az ad group show --group "$v" --query id -o tsv 2>/dev/null || echo "$v"
      else
        az ad group list --display-name "$v" --query '[0].id' -o tsv
      fi
      ;;
    ServicePrincipal)
      if is_guid "$v"; then
        az ad sp show --id "$v" --query id -o tsv 2>/dev/null \
          || az ad sp list --filter "appId eq '$v'" --query '[0].id' -o tsv
      else
        az ad sp list --display-name "$v" --query '[0].id' -o tsv
      fi
      ;;
  esac
}

PRINCIPAL_ID="$(resolve_principal "$PRINCIPAL")"
if [[ -z "${PRINCIPAL_ID:-}" || "$PRINCIPAL_ID" == "null" ]]; then
  echo "ERROR: could not resolve $PRINCIPAL_TYPE '$PRINCIPAL'" >&2
  exit 1
fi
echo "  principal:    $PRINCIPAL_TYPE '$PRINCIPAL' → $PRINCIPAL_ID"

# ───────── find storage accounts ─────────
REGEX="$(glob_to_regex "$RESOURCE_PATTERN")"
echo
echo "→ searching storage accounts matching '$RESOURCE_PATTERN' (regex: $REGEX)"

KQL="Resources
| where type =~ 'microsoft.storage/storageaccounts'
    and subscriptionId == '$SUB_ID'
    and name matches regex '$REGEX'
| project id, name
| order by name asc"

SCOPES=()
SKIP_TOKEN=""
while :; do
  if [[ -z "$SKIP_TOKEN" ]]; then
    PAGE="$(az graph query -q "$KQL" --first 100 -o json)"
  else
    PAGE="$(az graph query -q "$KQL" --first 100 --skip-token "$SKIP_TOKEN" -o json)"
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] && SCOPES+=("$id")
  done < <(jq -r '.data[].id' <<<"$PAGE")
  SKIP_TOKEN="$(jq -r '.skip_token // empty' <<<"$PAGE")"
  [[ -z "$SKIP_TOKEN" ]] && break
done

if (( ${#SCOPES[@]} == 0 )); then
  echo "No storage accounts matched pattern '$RESOURCE_PATTERN' in $SUB_ID." >&2
  exit 1
fi

echo "  matched ${#SCOPES[@]}:"
for s in "${SCOPES[@]}"; do echo "    - ${s##*/}"; done

# ───────── assign ─────────
echo
for SCOPE in "${SCOPES[@]}"; do
  NAME="${SCOPE##*/}"
  echo "==> $NAME"

  EXISTING="$(az role assignment list \
    --scope "$SCOPE" \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type "$PRINCIPAL_TYPE" \
    --role "$ROLE_ID" \
    --query '[].id' -o tsv 2>/dev/null || true)"

  if [[ -n "$EXISTING" ]]; then
    echo "    already assigned, skipping"
    continue
  fi

  az role assignment create \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type "$PRINCIPAL_TYPE" \
    --role "$ROLE_ID" \
    --scope "$SCOPE" \
    -o none
  echo "    assigned"
done

# ───────── verify ─────────
echo
echo "Verification:"
printf '  %-40s %s\n' "ACCOUNT" "ASSIGNMENTS"
for SCOPE in "${SCOPES[@]}"; do
  NAME="${SCOPE##*/}"
  COUNT="$(az role assignment list \
    --scope "$SCOPE" \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type "$PRINCIPAL_TYPE" \
    --role "$ROLE_ID" \
    --query 'length(@)' -o tsv)"
  printf '  %-40s %s\n' "$NAME" "$COUNT"
done