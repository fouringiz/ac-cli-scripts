#!/usr/bin/env bash
# setup-approles.sh — create/update Vault AppRoles across environments, read
# each role-id, and issue a fresh secret-id. DRY-RUN by default; --apply writes.
#
# Progress goes to stderr; only the report goes to stdout, grouped
# service -> ENV -> JSON (so `./setup-approles.sh --apply > creds.txt` is clean):
#   * <role>
#      * <ENV>
#         * { "role_id": "...", "secret_id": "..." }
#
# Tokens come from env vars VAULT_TOKEN_<ENV> (e.g. VAULT_TOKEN_DEV) — pull them
# from your secrets manager at run time; never hardcode or paste them anywhere.
#
# envs.conf:  <env> <vault_addr>
# roles.conf: <role> <policies> <token_ttl> <token_max_ttl>   (comma-sep policies ok)
# '#' comments and blank lines allowed in both.
#
# Roles whose managed fields (policies/ttl/max_ttl) already match are NOT
# rewritten: a Vault role write is a full replace and would reset unmanaged
# fields (secret_id_ttl, bound CIDRs, ...). Secret-id rotation happens anyway.
# No 'set -e': failures are counted and the run continues; exit 1 if any occurred.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVS_FILE="$DIR/envs.conf" ROLES_FILE="$DIR/roles.conf"
APPLY=0 YES=0 ONLY_ENV="" ONLY_ROLE="" TAB=$'\t'

usage() {
  echo "Usage: $(basename "$0") [--envs FILE] [--roles FILE] [--env A,B] [--role X,Y] [--apply] [--yes]"
  echo "  Dry-run by default. --apply writes. --yes skips the prod confirmation."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --envs)  ENVS_FILE="${2:?}"; shift 2 ;;
    --roles) ROLES_FILE="${2:?}"; shift 2 ;;
    --env)   ONLY_ENV="${2:?}"; shift 2 ;;
    --role)  ONLY_ROLE="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes)   YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v vault >/dev/null || { echo "ERROR: vault CLI not found." >&2; exit 1; }
ENVS="$(grep -vE '^[[:space:]]*(#|$)' "$ENVS_FILE")"  || { echo "ERROR: no envs in $ENVS_FILE" >&2; exit 1; }
ROLES="$(grep -vE '^[[:space:]]*(#|$)' "$ROLES_FILE")" || { echo "ERROR: no roles in $ROLES_FILE" >&2; exit 1; }

secs() { case "$1" in *s) echo $((${1%s}));; *m) echo $((${1%m}*60));; *h) echo $((${1%h}*3600));; *d) echo $((${1%d}*86400));; *) echo "$1";; esac; }
norm() { printf '%s' "$1" | tr -d '[]' | tr ' ,' '\n\n' | grep -v '^$' | sort -u | paste -sd, -; }
in_list() { [[ -z "$2" ]] || case ",$2," in *",$1,"*) ;; *) return 1 ;; esac; }

[[ $APPLY -eq 1 ]] && echo "MODE: APPLY — writing to Vault, fresh secret-ids will be issued." >&2 \
                   || echo "MODE: DRY RUN — nothing will be written. Re-run with --apply." >&2

errors=0; RESULTS=""   # role <TAB> env <TAB> role_id <TAB> secret, one per line
fail() { echo "    x $1" >&2; errors=$((errors+1)); }
add()  { RESULTS="${RESULTS}$1${TAB}$2${TAB}$3${TAB}$4
"; }

while IFS= read -r env_line; do
  read -r ENV ADDR _ <<< "$env_line"
  in_list "$ENV" "$ONLY_ENV" || continue

  TOKEN_VAR="VAULT_TOKEN_$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  if [[ -z "${!TOKEN_VAR:-}" ]]; then
    echo "==> Skipping '${ENV}': ${TOKEN_VAR} not set" >&2; continue
  fi
  export VAULT_ADDR="$ADDR" VAULT_TOKEN="${!TOKEN_VAR}"
  echo "== ${ENV} (${ADDR})" >&2
  [[ "$ADDR" == http://* ]] && echo "    WARNING: plaintext HTTP — token and secret-ids cross the network unencrypted." >&2

  if [[ $APPLY -eq 1 && $YES -eq 0 ]]; then case "$ENV" in prod|prd|production|*-prod|prod-*)
    printf "    PRODUCTION environment — type '%s' to continue: " "$ENV" >&2
    read -r ok </dev/tty 2>/dev/null || ok=""
    [[ "$ok" == "$ENV" ]] || { echo "    not confirmed (no TTY? use --yes) — skipping ${ENV}" >&2; continue; }
  esac; fi

  vault token lookup >/dev/null 2>&1 || { fail "${ENV}: auth failed (bad ${TOKEN_VAR} or Vault unreachable)"; continue; }

  while IFS= read -r role_line; do
    read -r ROLE POL TTL MAX _ <<< "$role_line"
    in_list "$ROLE" "$ONLY_ROLE" || continue
    [[ -n "${MAX:-}" ]] || { fail "${ENV}/${ROLE:-?}: malformed roles line (need 4 fields)"; continue; }
    RP="auth/approle/role/${ROLE}"
    echo "--- [${ENV}] ${ROLE}: policies=${POL} ttl=${TTL} max_ttl=${MAX}" >&2

    # Skip the write when the managed fields already match (see header).
    same=0
    cur_pol="$(vault read -field=token_policies "$RP" 2>/dev/null)" || cur_pol=""
    if [[ -n "$cur_pol" \
       && "$(norm "$cur_pol")" == "$(norm "$POL")" \
       && "$(vault read -field=token_ttl "$RP" 2>/dev/null)" == "$(secs "$TTL")" \
       && "$(vault read -field=token_max_ttl "$RP" 2>/dev/null)" == "$(secs "$MAX")" ]]; then same=1; fi

    if [[ $APPLY -eq 0 ]]; then
      rid="$(vault read -field=role_id "$RP/role-id" 2>/dev/null)" || rid="<none yet>"
      [[ $same -eq 1 ]] && echo "    = unchanged (would still issue a new secret-id)" >&2 \
                        || echo "    ~ would write role config and issue a NEW secret-id" >&2
      add "$ROLE" "$ENV" "$rid" "<dry run — not issued>"
      continue
    fi

    if [[ $same -eq 1 ]]; then
      echo "    = unchanged — write skipped" >&2
    elif out="$(vault write "$RP" policies="$POL" token_ttl="$TTL" token_max_ttl="$MAX" 2>&1)"; then
      echo "    + role written" >&2
    else
      fail "${ENV}/${ROLE}: write failed: ${out//$'\n'/ }"; add "$ROLE" "$ENV" "write failed" ""; continue
    fi

    rid="$(vault read -field=role_id "$RP/role-id" 2>&1)" \
      || { fail "${ENV}/${ROLE}: role-id read failed: ${rid//$'\n'/ }"; add "$ROLE" "$ENV" "role-id read failed" ""; continue; }
    sid="$(vault write -force -field=secret_id "$RP/secret-id" 2>&1)" \
      || { fail "${ENV}/${ROLE}: secret-id failed: ${sid//$'\n'/ }"; add "$ROLE" "$ENV" "$rid" "secret-id failed"; continue; }
    echo "    + role-id read, secret-id issued" >&2
    add "$ROLE" "$ENV" "$rid" "$sid"
  done <<< "$ROLES"
  unset VAULT_ADDR VAULT_TOKEN
done <<< "$ENVS"

# --- report: service -> ENV -> JSON, in conf-file order -----------------------
while IFS= read -r role_line; do
  read -r ROLE _ <<< "$role_line"
  in_list "$ROLE" "$ONLY_ROLE" || continue
  header=0
  while IFS= read -r env_line; do
    read -r ENV _ <<< "$env_line"
    in_list "$ENV" "$ONLY_ENV" || continue
    rec="$(printf '%s' "$RESULTS" | awk -F"$TAB" -v r="$ROLE" -v e="$ENV" '$1==r && $2==e {print $3 "\t" $4; exit}')"
    [[ -n "$rec" ]] || continue
    [[ $header -eq 0 ]] && { printf '* %s\n' "$ROLE"; header=1; }
    IFS="$TAB" read -r rid sid <<< "$rec"
    printf '   * %s\n      * {\n          "role_id": "%s",\n          "secret_id": "%s"\n        }\n' \
      "$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')" "$rid" "$sid"
  done <<< "$ENVS"
done <<< "$ROLES"

if [[ $errors -gt 0 ]]; then echo "==> Completed with ${errors} error(s) — see 'x' lines above." >&2; exit 1; fi
[[ $APPLY -eq 1 ]] && echo "==> Done. secret-ids above are live credentials — move them into your secrets store and clear scrollback/logs." >&2
