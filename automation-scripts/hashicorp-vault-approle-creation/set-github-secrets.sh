#!/usr/bin/env bash
# set-github-secrets.sh — push Vault AppRole creds into GitHub Actions repository
# secrets ({ENV}_..._ROLE_ID / {ENV}_..._SECRET_ID). DRY-RUN by default; --apply writes.
#
# Consumes the setup-approles.sh report, from a file or piped (keeps creds off disk).
# Env/role filtering and the prod gate happen upstream in setup-approles.sh:
#   ./setup-approles.sh --apply | ./set-github-secrets.sh --apply
#   ./set-github-secrets.sh creds.txt --apply
#
# repos.conf: <role> <owner/repo>    ('#' comments and blank lines allowed)
# gh must be authenticated (gh auth login / GH_TOKEN) — never hardcode tokens.
# Values go to gh via stdin, so they never appear in the process list.
# Placeholder/failed creds entries from an upstream dry run are skipped
# (dry-run) or counted as errors (--apply). Exit 1 if any error occurred.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL='{ENV}_QUARKUS_VAULT_AUTHENTICATION_APP_ROLE_{FIELD}'  # {FIELD}: ROLE_ID|SECRET_ID
REPOS="$DIR/repos.conf" CREDS="/dev/stdin" APPLY=0

for a in "$@"; do case "$a" in
  --apply)   APPLY=1 ;;
  -h|--help) echo "Usage: $(basename "$0") [creds-file] [--apply]"; exit 0 ;;
  *)         CREDS="$a" ;;
esac; done

command -v gh >/dev/null || { echo "ERROR: gh CLI not found." >&2; exit 1; }
[[ $APPLY -eq 0 ]] || gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (gh auth login)." >&2; exit 1; }
[[ "$CREDS" != /dev/stdin || ! -t 0 ]] || { echo "ERROR: give a creds file or pipe the report in." >&2; exit 1; }
[[ $APPLY -eq 1 ]] && echo "MODE: APPLY — writing repository secrets via gh." >&2 \
                   || echo "MODE: DRY RUN — nothing will be written. Re-run with --apply." >&2

errors=0
ok()  { [[ -n "$1" && "$1" != *'<'* && "$1" != *' '* && "$1" != *failed* ]]; }
put() { # <owner/repo> <name> <value>
  [[ $APPLY -eq 1 ]] || { echo "~ would set  $1  $2"; return; }
  if out="$(printf '%s' "$3" | gh secret set "$2" --repo "$1" 2>&1)"; then echo "+ set  $1  $2"
  else echo "x $1 $2: ${out//$'\n'/ }" >&2; errors=$((errors+1)); fi
}

ROLE="" ENV="" RID="" SID=""
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in '* '*) ROLE="${line#\* }"; continue ;; esac
  t="${line#"${line%%[![:space:]]*}"}"                       # ltrim
  case "$t" in
    '* {'*) RID="" SID="" ;;
    '* '*)  ENV="$(printf '%s' "${t#\* }" | tr '[:lower:]' '[:upper:]')" ;;
    '"role_id"'*)   RID="${t#*: \"}"; RID="${RID%%\"*}" ;;
    '"secret_id"'*) SID="${t#*: \"}"; SID="${SID%%\"*}"
      repo="$(awk -v r="$ROLE" '/^[[:space:]]*(#|$)/{next} $1==r{print $2; exit}' "$REPOS")"
      [[ -n "$repo" ]] || { echo "==> skipping '${ROLE}': not in repos.conf" >&2; continue; }
      if ! ok "$RID" || ! ok "$SID"; then
        [[ $APPLY -eq 1 ]] && { echo "x ${ENV}/${ROLE}: unusable creds values — not written" >&2; errors=$((errors+1)); } \
                           || echo "~ ${ENV}/${ROLE}: creds not issued (dry-run input) — skipped" >&2
        continue
      fi
      n="${TMPL//\{ENV\}/$ENV}"
      put "$repo" "${n//\{FIELD\}/ROLE_ID}"   "$RID"
      put "$repo" "${n//\{FIELD\}/SECRET_ID}" "$SID" ;;
  esac
done < "$CREDS"

[[ $errors -eq 0 ]] || { echo "==> Completed with ${errors} error(s)." >&2; exit 1; }
[[ $APPLY -eq 1 ]] && echo "==> Done. If the creds came from a file, delete it once verified." >&2
exit 0
