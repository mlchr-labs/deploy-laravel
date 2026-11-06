#!/usr/bin/env bash
#
# Phase 4, credentials. Runs on YOUR machine (not on the server).
#
#   1. Generates an ed25519 key in a temporary directory.
#   2. Installs the public key in ~<deploy_user>/.ssh/authorized_keys with the
#      "restrict" prefix, through the existing root SSH alias (backup first,
#      idempotent).
#   3. Reads the server host key through that same trusted channel and builds
#      the known_hosts line (no ssh-keyscan).
#   4. Tests the new key: whoami, write access to releases/, artisan/supervisor.
#   5. Optionally (asks first) creates the GitHub "production" environment and
#      sets secrets and variables with gh.
#   6. Deletes the private key from disk on exit. It only lives in the secret.
#
# Usage:
#   ROOT_ALIAS=myserver HOST=203.0.113.10 PORT=22 DEPLOY_USER=deploy \
#   DEPLOY_PATH=/var/www/example.com REPO=org/repo \
#   PHP_BIN=php8.3 bash scripts/setup-deploy-key.sh
#
# With several gh accounts, select the one with access to the repository:
#   GH_TOKEN="$(gh auth token -u <account>)" ROOT_ALIAS=... bash scripts/setup-deploy-key.sh

set -Eeuo pipefail

ROOT_ALIAS="${ROOT_ALIAS:?ROOT_ALIAS is required (ssh alias with root access)}"
HOST="${HOST:?HOST is required (public IP or hostname)}"
PORT="${PORT:-22}"
DEPLOY_USER="${DEPLOY_USER:?DEPLOY_USER is required}"
DEPLOY_PATH="${DEPLOY_PATH:?DEPLOY_PATH is required}"
REPO="${REPO:?REPO is required (org/repo)}"
PHP_BIN="${PHP_BIN:-php8.3}"
ENVIRONMENT="${ENVIRONMENT:-production}"

[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "invalid HOST" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "invalid PORT" >&2; exit 1; }
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid DEPLOY_USER" >&2; exit 1; }
[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$DEPLOY_PATH" != *..* ]] || { echo "invalid DEPLOY_PATH" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "invalid REPO" >&2; exit 1; }
[[ "$PHP_BIN" =~ ^php[0-9.]*$ ]] || { echo "invalid PHP_BIN" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

KEY="$WORKDIR/deploy_key"
KNOWN_HOSTS="$WORKDIR/known_hosts"

step() { printf '\n==> %s\n' "$*"; }

step "1. Generating ed25519 key"
ssh-keygen -q -t ed25519 -N '' -C "github-actions-deploy@${REPO}" -f "$KEY"
PUB_TYPE="$(awk '{print $1}' "$KEY.pub")"
PUB_BODY="$(awk '{print $2}' "$KEY.pub")"
AUTH_LINE="restrict $(cat "$KEY.pub")"

step "2. Installing public key for $DEPLOY_USER via $ROOT_ALIAS"
# shellcheck disable=SC2029 # values are validated and quoted with %q
ssh "$ROOT_ALIAS" "DEPLOY_USER=$(printf '%q' "$DEPLOY_USER") PUB_BODY=$(printf '%q' "$PUB_BODY") AUTH_LINE=$(printf '%q' "$AUTH_LINE") bash -s" <<'REMOTE'
set -euo pipefail
home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
[ -n "$home" ] || { echo "user $DEPLOY_USER not found" >&2; exit 1; }
group="$(id -gn "$DEPLOY_USER")"
install -d -m 700 -o "$DEPLOY_USER" -g "$group" "$home/.ssh"
ak="$home/.ssh/authorized_keys"
if [ -f "$ak" ]; then
  cp -p "$ak" "$ak.bak-$(date +%Y%m%d%H%M%S)"
else
  touch "$ak"
fi
if grep -qF -- "$PUB_BODY" "$ak"; then
  echo "key already present, nothing appended"
else
  printf '%s\n' "$AUTH_LINE" >> "$ak"
  echo "key appended"
fi
chown "$DEPLOY_USER:$group" "$ak"
chmod 600 "$ak"
REMOTE

step "3. Reading host key through the trusted channel"
HOST_KEY="$(ssh "$ROOT_ALIAS" cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')"
[[ "$HOST_KEY" == ssh-ed25519\ * ]] || { echo "could not read the ed25519 host key" >&2; exit 1; }
if [[ "$PORT" == "22" ]]; then
  KH_HOST="$HOST"
else
  KH_HOST="[$HOST]:$PORT"
fi
printf '%s %s\n' "$KH_HOST" "$HOST_KEY" > "$KNOWN_HOSTS"
cat "$KNOWN_HOSTS"

step "4. Testing the new key (strict host key checking)"
# -F /dev/null ignores your personal ~/.ssh/config, the test must reflect
# exactly what GitHub Actions will do.
# shellcheck disable=SC2029
ssh -F /dev/null -i "$KEY" -p "$PORT" \
  -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$DEPLOY_USER@$HOST" \
  "set -e
   echo \"whoami: \$(whoami)\"
   test -w $(printf '%q' "$DEPLOY_PATH/releases") && echo 'releases/: writable' || echo 'releases/: NOT writable'
   test -f $(printf '%q' "$DEPLOY_PATH/shared/.env") && echo 'shared/.env: present' || echo 'shared/.env: MISSING'
   if [ -f $(printf '%q' "$DEPLOY_PATH/current/artisan") ]; then cd $(printf '%q' "$DEPLOY_PATH/current") && $PHP_BIN artisan --version; fi
   if command -v supervisorctl >/dev/null; then supervisorctl status || echo 'supervisorctl: no access'; fi"

step "5. GitHub ($REPO, environment $ENVIRONMENT)"
echo "Account: $(gh api user --jq .login)"
read -r -p "Create the environment and set secrets/variables now? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  gh api -X PUT "repos/$REPO/environments/$ENVIRONMENT" >/dev/null
  gh secret set DEPLOY_SSH_KEY --repo "$REPO" --env "$ENVIRONMENT" < "$KEY"
  gh secret set DEPLOY_KNOWN_HOSTS --repo "$REPO" --env "$ENVIRONMENT" < "$KNOWN_HOSTS"
  gh variable set DEPLOY_HOST --repo "$REPO" --env "$ENVIRONMENT" --body "$HOST"
  gh variable set DEPLOY_PORT --repo "$REPO" --env "$ENVIRONMENT" --body "$PORT"
  gh variable set DEPLOY_USER --repo "$REPO" --env "$ENVIRONMENT" --body "$DEPLOY_USER"
  gh variable set DEPLOY_PATH --repo "$REPO" --env "$ENVIRONMENT" --body "$DEPLOY_PATH"
  echo "GitHub configured."
else
  echo "Skipped. The private key will be deleted now, so the public key just"
  echo "installed is orphaned. Remove the line ending in 'github-actions-deploy@$REPO'"
  echo "from ~$DEPLOY_USER/.ssh/authorized_keys before running this script again."
fi

step "6. Removing local private key"
cleanup
echo "Done. Public key fingerprint: $(printf '%s %s\n' "$PUB_TYPE" "$PUB_BODY" | ssh-keygen -lf - 2>/dev/null || echo 'n/a')"
