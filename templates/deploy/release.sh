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

# ---- 1. Extract ------------------------------------------------------------
log "extracting $RELEASE_ID"
mkdir -p "$RELEASE_DIR"
tar -xzf "$ARCHIVE" -C "$RELEASE_DIR"
rm -f -- "$ARCHIVE"

# ---- 2. Shared links -------------------------------------------------------
log "linking shared files"
# Idempotent, creates the tree on the first deploy.
mkdir -p \
  "$SHARED_DIR/storage/app/public" \
  "$SHARED_DIR/storage/framework/cache/data" \
  "$SHARED_DIR/storage/framework/sessions" \
  "$SHARED_DIR/storage/framework/views" \
  "$SHARED_DIR/storage/logs"

ln -sfn "$SHARED_DIR/.env" "$RELEASE_DIR/.env"
# rm + ln: "ln -s" pointing at an existing directory would create a nested
# link (storage/storage) instead of replacing it.
rm -rf -- "$RELEASE_DIR/storage"
ln -sfn "$SHARED_DIR/storage" "$RELEASE_DIR/storage"
mkdir -p "$RELEASE_DIR/bootstrap/cache"

# CUSTOMIZE: extra shared paths, always with rm + ln. Example:
# rm -rf -- "$RELEASE_DIR/public/uploads"
# ln -sfn "$SHARED_DIR/public/uploads" "$RELEASE_DIR/public/uploads"

cd "$RELEASE_DIR"

# ---- 3. Composer -----------------------------------------------------------
# Runs with the runtime PHP so platform_check and extensions match FPM.
log "composer install"
"$PHP_BIN" "$COMPOSER_BIN" install \
  --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress

# ---- 4. Laravel (inside the new release, .env already linked) --------------
if [[ "$STORAGE_LINK" == "1" && ! -e public/storage ]]; then
  log "storage:link"
  artisan storage:link
fi

if [[ "$RUN_MIGRATIONS" == "1" ]]; then
  log "migrate"
  artisan migrate --force
fi

log "optimize"
# Laravel 11+ caches config, events, routes and views. On older versions
# replace with: config:cache, route:cache, view:cache, event:cache.
artisan optimize

# ---- 5. Permissions (release only, no sudo) --------------------------------
log "permissions"
chown -R "$DEPLOY_USER:$WEB_GROUP" "$RELEASE_DIR"
chmod -R g+rwX "$RELEASE_DIR/bootstrap/cache"
# Only touch what the deploy user owns, files created by PHP-FPM belong to
# another user and chmod on them would fail.
find "$SHARED_DIR/storage" -user "$DEPLOY_USER" -exec chmod g+rwX {} +
find "$SHARED_DIR/storage" -type d -user "$DEPLOY_USER" -exec chmod g+s {} +

# ---- 6. Atomic activation --------------------------------------------------
PREVIOUS="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
log "activating (previous: ${PREVIOUS:-none})"
ln -sfn "$RELEASE_DIR" "$CURRENT_NEW"
mv -Tf "$CURRENT_NEW" "$CURRENT_LINK"
ACTIVATED=1

# ---- 7. Queues -------------------------------------------------------------
cd "$CURRENT_LINK"
case "$QUEUE_MODE" in
  queue)   log "queue:restart";      artisan queue:restart ;;
  horizon) log "horizon:terminate";  artisan horizon:terminate ;;
  none)    ;;
esac
for program in $SUPERVISOR_PROGRAMS; do
  log "supervisorctl restart $program:*"
  supervisorctl restart "$program:*"
done

# ---- 8. OPcache --------------------------------------------------------------
# Nothing to do when Nginx passes $realpath_root in SCRIPT_FILENAME and
# DOCUMENT_ROOT (see templates/nginx/laravel-realpath.conf). Reloading PHP-FPM
# needs sudo and is out of scope for this script.

# ---- 9. Retention ----------------------------------------------------------
# Only directories matching the release id format are considered, legacy
# releases from another deployer are left untouched.
log "retention: keeping $KEEP_RELEASES releases"
ACTIVE="$(readlink -f "$CURRENT_LINK")"
mapfile -t ALL_RELEASES < <(
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E '^[0-9]{14}-[0-9a-f]{7}$' | sort -r || true
)
for old in "${ALL_RELEASES[@]:$KEEP_RELEASES}"; do
  [[ "$RELEASES_DIR/$old" == "$ACTIVE" ]] && continue
  log "removing old release $old"
  rm -rf -- "${RELEASES_DIR:?}/$old" || log "warning: could not fully remove $old"
done

log "done, current -> $RELEASE_DIR"
