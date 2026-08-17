# Vault AppRole → GitHub Actions secrets

Provisions Vault AppRoles per environment, rotates their secret-ids, and pushes
the credentials into GitHub Actions repository secrets
(`{ENV}_QUARKUS_VAULT_AUTHENTICATION_APP_ROLE_ROLE_ID` / `..._SECRET_ID`) —
in one pipe, so the secret-ids never touch disk.

## Usage

Both scripts are **dry-run by default**; `--apply` writes.

```bash
export VAULT_TOKEN_DEV=... VAULT_TOKEN_TEST=...   # from your secrets manager
./setup-approles.sh | ./set-github-secrets.sh                    # preview
./setup-approles.sh --apply | ./set-github-secrets.sh --apply    # apply

./setup-approles.sh --apply > creds.txt                          # or two-step:
./set-github-secrets.sh creds.txt --apply && shred -u creds.txt
```

`--env A,B` / `--role X,Y` filters and the interactive prod gate (`--yes` to
skip) live in `setup-approles.sh` and carry through the pipe.

## Config (`#` comments and blank lines allowed)

- `envs.conf` — `<env> <vault_addr>`
- `roles.conf` — `<role> <policies> <token_ttl> <token_max_ttl>`
- `repos.conf` — `<role> <owner/repo>`

## Notes

- Progress → stderr; report → stdout. Failures are counted, not fatal; exit 1 if any.
- Auth: `VAULT_TOKEN_<ENV>` env vars and the `gh` session — nothing hardcoded,
  secret values passed via stdin, never argv.
- Every `--apply` issues a fresh secret-id and overwrites the GitHub secret;
  placeholder/failed entries are never pushed; unmapped roles are skipped.

Requires: `bash`, `vault` CLI, `gh` CLI (admin on the target repos).
