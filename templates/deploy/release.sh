#!/usr/bin/env bash
#
# Atomic release script for Laravel (releases + symlink, Envoyer style).
#
# Runs ON THE SERVER as the deploy user. The GitHub Actions workflow uploads
# releases/<release_id>.tar.gz and then streams this file over SSH:
#
#   ssh deploy-target "DEPLOY_PATH='/var/www/example.com' bash -s -- '<release_id>'" < deploy/release.sh
#
# Layout under DEPLOY_PATH:
#   current -> releases/<release_id>     (symlink, swapped atomically)
#   releases/<release_id>/               (one directory per deploy)
#   shared/.env                          (production env, never in git)
#   shared/storage/                      (persistent storage)
#
# Every value in the CONFIG block can be overridden by an environment variable
# of the same name.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# CONFIG (CUSTOMIZE per project)
# ----------------------------------------------------------------------------
# Versioned PHP binary used by PHP-FPM and the queue workers. Never rely on
# /usr/bin/php, it may point to another version.
PHP_BIN="${PHP_BIN:-php8.3}"
COMPOSER_BIN="${COMPOSER_BIN:-/usr/bin/composer}"
# Group used by the web server. The deploy user must belong to it.
WEB_GROUP="${WEB_GROUP:-www-data}"
# How many releases to keep, the active one is never removed.
KEEP_RELEASES="${KEEP_RELEASES:-5}"
# 1 runs "artisan migrate --force" before activation. Migrations must be
# backward compatible (expand/contract): the old code keeps serving traffic
# until the symlink swap.
RUN_MIGRATIONS="${RUN_MIGRATIONS:-1}"
# 1 runs "artisan storage:link" (only needed when the public disk is used).
STORAGE_LINK="${STORAGE_LINK:-1}"
# queue   -> artisan queue:restart
# horizon -> artisan horizon:terminate
# none    -> no queue workers
QUEUE_MODE="${QUEUE_MODE:-queue}"
# Space separated supervisor program names restarted with
# "supervisorctl restart '<program>:*'". Leave empty to skip. Requires the
# supervisor socket to be accessible by the deploy user's group.
SUPERVISOR_PROGRAMS="${SUPERVISOR_PROGRAMS:-}"
# ----------------------------------------------------------------------------

RELEASE_ID="${1:-}"
DEPLOY_PATH="${DEPLOY_PATH:-}"

log() { printf '[release %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[release %s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# ---- Input validation ------------------------------------------------------
[[ "$RELEASE_ID" =~ ^[0-9]{14}-[0-9a-f]{7}$ ]] \
  || die "invalid release id '$RELEASE_ID', expected YYYYMMDDHHMMSS-<sha7>"
[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$DEPLOY_PATH" != *..* ]] \
  || die "DEPLOY_PATH must be an absolute path without '..'"
DEPLOY_PATH="${DEPLOY_PATH%/}"
[[ "$PHP_BIN" =~ ^(/[A-Za-z0-9._/-]+/)?php[0-9.]*$ ]] || die "invalid PHP_BIN '$PHP_BIN'"
[[ "$KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "KEEP_RELEASES must be a positive integer"
case "$QUEUE_MODE" in queue|horizon|none) ;; *) die "QUEUE_MODE must be queue, horizon or none" ;; esac
for program in $SUPERVISOR_PROGRAMS; do
  [[ "$program" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid supervisor program '$program'"
done

RELEASES_DIR="$DEPLOY_PATH/releases"
SHARED_DIR="$DEPLOY_PATH/shared"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
ARCHIVE="$RELEASES_DIR/$RELEASE_ID.tar.gz"
CURRENT_LINK="$DEPLOY_PATH/current"
CURRENT_NEW="$DEPLOY_PATH/current.new"
DEPLOY_USER="$(id -un)"

# ---- Preconditions ---------------------------------------------------------
[[ -f "$ARCHIVE" ]] || die "package not found: $ARCHIVE"
[[ -f "$SHARED_DIR/.env" ]] || die "missing $SHARED_DIR/.env"
[[ ! -e "$RELEASE_DIR" ]] || die "release already exists: $RELEASE_DIR"
if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  die "$CURRENT_LINK exists and is not a symlink, migrate the layout manually first"
fi
command -v "$PHP_BIN" >/dev/null || die "PHP binary not found: $PHP_BIN"
[[ -r "$COMPOSER_BIN" ]] || die "composer not found: $COMPOSER_BIN"
if [[ -n "$SUPERVISOR_PROGRAMS" ]]; then
  command -v supervisorctl >/dev/null || die "supervisorctl not found"
fi

# ---- Failure handling ------------------------------------------------------
# Before activation: remove the incomplete release and the package, "current"
# keeps pointing to the previous release.
# After activation: the new code is live, only the post activation steps
# (queues, retention) failed. Nothing is removed.
ACTIVATED=0
on_error() {
  local code=$?
  trap - ERR
  if [[ "$ACTIVATED" -eq 0 ]]; then
    log "failed before activation (exit $code), removing incomplete release"
    rm -rf -- "$RELEASE_DIR" "$ARCHIVE" "$CURRENT_NEW"
    log "current still points to: $(readlink "$CURRENT_LINK" 2>/dev/null || echo 'nothing')"
  else
    log "failed AFTER activation (exit $code), $RELEASE_ID is live, check workers manually"
  fi
  exit "$code"
}
trap on_error ERR

umask 0002

artisan() { "$PHP_BIN" artisan "$@"; }

