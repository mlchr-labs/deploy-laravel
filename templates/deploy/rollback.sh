#!/usr/bin/env bash
#
# Manual rollback: points "current" to an existing release.
#
# Runs ON THE SERVER as the deploy user:
#
#   DEPLOY_PATH=/var/www/example.com bash deploy/rollback.sh            # previous release
#   DEPLOY_PATH=/var/www/example.com bash deploy/rollback.sh <release>  # specific release
#
# Or from your machine, without copying the file to the server:
#
#   ssh <deploy-alias> "DEPLOY_PATH='/var/www/example.com' bash -s -- '<release>'" < deploy/rollback.sh
#
# Migrations are NOT reverted. This is safe only because migrations are
# backward compatible (expand/contract).

set -Eeuo pipefail

PHP_BIN="${PHP_BIN:-php8.3}"
QUEUE_MODE="${QUEUE_MODE:-queue}"
SUPERVISOR_PROGRAMS="${SUPERVISOR_PROGRAMS:-}"
DEPLOY_PATH="${DEPLOY_PATH:-}"
TARGET="${1:-}"

log() { printf '[rollback] %s\n' "$*"; }
die() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$DEPLOY_PATH" != *..* ]] \
  || die "DEPLOY_PATH must be an absolute path without '..'"
DEPLOY_PATH="${DEPLOY_PATH%/}"
RELEASES_DIR="$DEPLOY_PATH/releases"
CURRENT_LINK="$DEPLOY_PATH/current"

ACTIVE="$(basename "$(readlink -f "$CURRENT_LINK")")"

if [[ -z "$TARGET" ]]; then
  # Newest release older than the active one.
  TARGET="$(
    find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | grep -E '^[0-9]{14}-[0-9a-f]{7}$' | sort -r \
      | awk -v active="$ACTIVE" 'found { print; exit } $0 == active { found = 1 }'
  )"
  [[ -n "$TARGET" ]] || die "no release older than $ACTIVE"
fi

[[ "$TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release name '$TARGET'"
[[ -d "$RELEASES_DIR/$TARGET" ]] || die "release not found: $RELEASES_DIR/$TARGET"
[[ "$TARGET" != "$ACTIVE" ]] || die "$TARGET is already active"

log "switching $ACTIVE -> $TARGET"
ln -sfn "$RELEASES_DIR/$TARGET" "$DEPLOY_PATH/current.new"
mv -Tf "$DEPLOY_PATH/current.new" "$CURRENT_LINK"

cd "$CURRENT_LINK"
# The target release keeps the config cache built when it was deployed. If
# shared/.env changed since then, rebuild it: "$PHP_BIN" artisan optimize
case "$QUEUE_MODE" in
  queue)   "$PHP_BIN" artisan queue:restart ;;
  horizon) "$PHP_BIN" artisan horizon:terminate ;;
  none)    ;;
  *) die "QUEUE_MODE must be queue, horizon or none" ;;
esac
for program in $SUPERVISOR_PROGRAMS; do
  [[ "$program" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid supervisor program '$program'"
  supervisorctl restart "$program:*"
done

log "done, current -> $RELEASES_DIR/$TARGET"
