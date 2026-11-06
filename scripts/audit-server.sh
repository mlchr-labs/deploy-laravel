#!/usr/bin/env bash
#
# Phase 1, read-only server audit. Prints facts, changes nothing.
#
# Run as root through the existing root SSH alias, from your machine:
#
#   ssh <root-alias> "BASE=/var/www/example.com DEPLOY_USER=deploy PHP_VERSION=8.3 bash -s" < scripts/audit-server.sh
#
# Secrets are never printed: for .env only key names are shown, plus values
# that look like filesystem paths.

set -uo pipefail

BASE="${BASE:?BASE is required, e.g. /var/www/example.com}"
DEPLOY_USER="${DEPLOY_USER:?DEPLOY_USER is required}"
PHP_VERSION="${PHP_VERSION:?PHP_VERSION is required, e.g. 8.3}"
PHP_BIN="php${PHP_VERSION}"

section() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '\n'; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "warning: not running as root, some checks will be incomplete" >&2
fi

section "1. Document root layout ($BASE)"
run ls -la "$BASE"
if [[ -L "$BASE/current" ]]; then
  echo "current -> $(readlink "$BASE/current")"
  echo "resolved: $(readlink -f "$BASE/current")"
else
  echo "current is NOT a symlink (or does not exist)"
fi
if [[ -d "$BASE/releases" ]]; then
  echo "releases (newest first):"
  find "$BASE/releases" -mindepth 1 -maxdepth 1 -printf '%TY-%Tm-%Td %TH:%TM  %f\n' | sort -r | head -n 15
fi
if [[ -d "$BASE/shared" ]]; then
  run ls -la "$BASE/shared"
fi
if [[ -L "$BASE/current" ]]; then
  echo "links inside the active release:"
  find "$(readlink -f "$BASE/current")" -maxdepth 2 -type l -printf '%p -> %l\n' 2>/dev/null | grep -v '/vendor/'
fi

section "2. Existing deploy tooling"
run ls -la "$BASE/.dep" "$BASE/.envoyer" 2>/dev/null
for f in /root/.ssh/authorized_keys "$(getent passwd "$DEPLOY_USER" | cut -d: -f6)/.ssh/authorized_keys"; do
  [[ -f "$f" ]] || continue
  echo "key comments in $f (look for envoyer, deployer, ploi, forge):"
  awk '{print $NF}' "$f"
done
echo "crontab of $DEPLOY_USER:"
crontab -l -u "$DEPLOY_USER" 2>&1

section "3. Nginx"
nginx_files="$(grep -rlsF "$BASE" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null || true)"
if [[ -z "$nginx_files" ]]; then
  echo "no vhost references $BASE"
fi
for f in $nginx_files; do
  echo "--- $f"
  grep -nE '^\s*(server_name|root|fastcgi_pass|fastcgi_param\s+(SCRIPT_FILENAME|DOCUMENT_ROOT)|include)\b' "$f"
done
echo "PHP-FPM sockets:"
ls -la /run/php/ 2>/dev/null

section "4. Supervisor"
run ls -la /etc/supervisor/conf.d/
for f in /etc/supervisor/conf.d/*.conf; do
  [[ -f "$f" ]] || continue
  echo "--- $f"
  grep -nE '^\s*(\[program:|directory|command|user|numprocs)' "$f"
done
echo "socket config:"
awk '/^\[unix_http_server\]/{p=1; print; next} /^\[/{p=0} p' /etc/supervisor/supervisord.conf 2>/dev/null
sock="$(awk -F= '/^\[unix_http_server\]/{p=1; next} /^\[/{p=0} p && $1 ~ /^file/ {gsub(/ /, "", $2); print $2}' /etc/supervisor/supervisord.conf 2>/dev/null)"
[[ -n "$sock" ]] && run ls -la "$sock"
run supervisorctl status

section "5. Deploy user"
run id "$DEPLOY_USER"
run sudo -l -U "$DEPLOY_USER"

section "6. PHP"
run command -v "$PHP_BIN"
run "$PHP_BIN" -v
echo "/usr/bin/php -> $(readlink -f /usr/bin/php 2>/dev/null || echo 'not found')"
run php -v
if [[ -L "$BASE/current" && -f "$BASE/current/composer.json" ]]; then
  echo "extensions required by composer.json vs installed in $PHP_BIN:"
  installed="$("$PHP_BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  grep -oE '"ext-[A-Za-z0-9_]+"' "$BASE/current/composer.json" | tr -d '"' | sed 's/^ext-//' | sort -u \
    | while read -r ext; do
        if grep -qx "$(tr '[:upper:]' '[:lower:]' <<<"$ext")" <<<"$installed"; then
          echo "  ok      $ext"
        else
          echo "  MISSING $ext"
        fi
      done
fi
run ls -la /usr/bin/composer /usr/local/bin/composer

section "7. Production .env (keys only, paths shown)"
envfile="$BASE/shared/.env"
[[ -f "$envfile" ]] || envfile="$BASE/current/.env"
if [[ -f "$envfile" ]]; then
  echo "file: $envfile"
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$envfile" | while IFS='=' read -r key value; do
    value="${value%\"}"; value="${value#\"}"
    if [[ "$value" == /* || "$value" == storage/* ]]; then
      echo "  $key=$value"
    else
      echo "  $key"
    fi
  done
else
  echo "no .env found in shared/ or current/"
fi

section "8. SSH keys of $DEPLOY_USER"
home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
run ls -la "$home/.ssh"
echo "GitHub identity of the deploy user (Hi <account> = user key, report as risk):"
if command -v runuser >/dev/null; then
  runuser -u "$DEPLOY_USER" -- ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 git@github.com 2>&1 | head -n 3
else
  sudo -u "$DEPLOY_USER" ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 git@github.com 2>&1 | head -n 3
fi

section "Done"
