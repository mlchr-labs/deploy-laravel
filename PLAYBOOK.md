# Playbook: Laravel deploy to a VPS with GitHub Actions (releases + symlink)

Instructions for an AI agent working inside an **existing Laravel project**. Goal: set up
continuous deploy to a VPS over SSH from GitHub Actions, with atomic releases in the
Deployer/Envoyer style and no external service.

Templates referenced below live in this repository (`mlchr-labs/deploy-laravel`). Copy
them into the target project and adapt them, do not reference them remotely at runtime.

| Template | Destination in the Laravel project |
|---|---|
| `templates/deploy/release.sh` | `deploy/release.sh` |
| `templates/deploy/rollback.sh` | `deploy/rollback.sh` |
| `templates/.github/workflows/deploy.yml` | `.github/workflows/deploy.yml` |
| `templates/README-deploy.md` | "Deploy" section of the project README |
| `templates/PULL_REQUEST.md` | Body of the pull request |
| `templates/nginx/laravel-realpath.conf` | Reference only, never applied without approval |
| `templates/supervisor/laravel-worker.conf` | Reference only, never applied without approval |
| `scripts/audit-server.sh` | Not copied, run once for Phase 1 |
| `scripts/setup-deploy-key.sh` | Not copied, run once for Phase 4 |

## Inputs (fill in before starting)

Ask the human for anything missing. Do not guess hosts, users or paths.

| Input | Example |
|---|---|
| GitHub repository and production branch | `org/repo`, `main` |
| Local SSH alias with root access (preparation only) | `myserver` |
| Public IP or host, SSH port | `203.0.113.10`, `22` |
| Deploy user (owns the files, no sudo) | `deploy` |
| Document root (deploy base) | `/var/www/example.com` |
| Runtime PHP version (PHP-FPM and workers) | `8.3`, binary `php8.3` |
| Queue manager | supervisor (program names) or Horizon or none |
| Front-end build | Vite yes/no, package manager from the lockfile |
| gh account with admin access to the repo | `my-account` |

## Authorization scope

Allowed:

- create the deploy key, edit `authorized_keys` of the deploy user, work inside the
  project document root;
- configure the GitHub environment, secrets and variables.

Not allowed without asking first:

- sudoers, Nginx, PHP-FPM, supervisor configs, the database;
- running migrations, running the workflow or `release.sh` in production;
- merging into `main`. Merging the PR is the first real deploy and belongs to the
  project owner.

How the human grants SSH access to the agent is described in
[docs/ai-ssh-access.md](docs/ai-ssh-access.md). If no SSH access was granted, ask the
human to run `scripts/audit-server.sh` and paste the output.

## Phase 1: survey the current state (read only)

Run `scripts/audit-server.sh` through the root alias:

```bash
ssh <root-alias> "BASE=/var/www/example.com DEPLOY_USER=deploy PHP_VERSION=8.3 bash -s" < scripts/audit-server.sh
```

Then confirm each point:

1. **Document root layout.** Is there `current -> releases/<id>`? What is in `shared/`?
   Which links does each release have to `shared` (`.env`, `storage`)?
2. **Current deploy.** Existing workflow, external deployer (Envoyer, Deployer, Forge,
   Ploi) and its hooks. **The hook list is the specification**: reproduce the same order.
   Ask the human for the hook list if it lives only in a web panel.
3. **Nginx.** `root` must be `<base>/current/public`. Note the PHP-FPM socket and version,
   and whether `fastcgi_param` uses `$realpath_root` or `$document_root`.
4. **Supervisor.** Programs, `directory=` (must be `<base>/current`), `user=` and the PHP
   binary used. Check the socket in `/etc/supervisor/supervisord.conf` (`chmod`/`chown`
   of `[unix_http_server]`). If the deploy user's group has access, it can run
   `supervisorctl` without sudo. If not, **stop and ask**, it requires a change outside
   the scope.
5. **Deploy user.** `id <deploy_user>` must show the web server group (for example
   `www-data`). `sudo -l -U <deploy_user>` should show no sudo rights.
6. **PHP.** Does `php<x.y> -m` include every `ext-*` from `composer.json`? Does
   `/usr/bin/php` point to the same version as FPM? If not, use the versioned binary
   everywhere.
7. **Production `.env`.** Confirm absolute paths (storage, logs, certificates). Print only
   key names and paths, **never values of secrets**.
8. **Existing keys in `~<deploy_user>/.ssh`.** If any key authenticates on GitHub as a
   user account (`ssh -T git@github.com` prints `Hi <account>`), **report it as a risk**.

Report the findings to the human before writing code. Flag anything from
[Known pitfalls](#known-pitfalls).

## Phase 2: versioned release script (`deploy/release.sh`)

Start from `templates/deploy/release.sh`. Bash with `set -Eeuo pipefail`, executed on the
server as the deploy user. Edit only the `CONFIG` block and the `CUSTOMIZE` markers.

The template already implements:

1. Release id validated with the regex `^[0-9]{14}-[0-9a-f]{7}$` (`YYYYMMDDHHMMSS-<sha7>`).
2. Preconditions: the package `releases/<id>.tar.gz` exists, `shared/.env` exists, the
   release does not exist yet, `current` is a symlink (or absent).
3. `trap ERR`: on failure **before** activation it removes the incomplete release and the
   package. `current` stays on the previous release.
4. Extraction into `releases/<id>/`, then the `.tar.gz` is deleted.
5. Shared links:
   - `ln -sfn <base>/shared/.env <release>/.env`;
   - `rm -rf <release>/storage && ln -sfn <base>/shared/storage <release>/storage`;
   - creation of `shared/storage/{app/public,framework/{cache,sessions,views},logs}`.
6. `php<x.y> /usr/bin/composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist --no-progress`,
   with the runtime PHP so `platform_check` and extensions match.
7. Laravel, before activation, inside the new release with `.env` already linked:
   `storage:link` (optional), `migrate --force` (optional), `optimize`.
8. Permissions on the release only (`chown -R <deploy_user>:www-data`), group write on
   `shared/storage` and `bootstrap/cache`, no sudo. This runs **before** activation so the
   release is never live with wrong permissions.
9. Atomic activation: `ln -sfn <release> <base>/current.new && mv -Tf <base>/current.new <base>/current`.
10. Queues: `queue:restart` or `horizon:terminate`, plus
    `supervisorctl restart '<program>:*'` for each program in `SUPERVISOR_PROGRAMS`.
11. Retention: keeps the newest `KEEP_RELEASES`, never the active one, ignores directories
    that do not match the release id format (legacy releases stay until removed by hand).

What you must adapt:

- `PHP_BIN`, `WEB_GROUP`, `QUEUE_MODE`, `SUPERVISOR_PROGRAMS`, `STORAGE_LINK`,
  `RUN_MIGRATIONS`, `KEEP_RELEASES`;
- extra shared paths found in Phase 1 (always `rm -rf` then `ln -sfn`);
- any hook from the old deployer not covered above, in the same order;
- `artisan optimize` on Laravel versions older than 11 (see the comment in the script).

**OPcache and realpath cache.** Preferred: Nginx passes `$realpath_root` in
`SCRIPT_FILENAME` and `DOCUMENT_ROOT`, so every request resolves the new release without
reloading FPM. If the vhost uses `$document_root`, **ask** before changing Nginx or
reloading FPM (both need sudo). A middle ground without sudo is
`opcache.validate_timestamps=1`. Report which situation applies.

## Phase 3: workflow (`.github/workflows/deploy.yml`)

Start from `templates/.github/workflows/deploy.yml`. It already has:

- `on: push` to `main` and `workflow_dispatch`;
- `environment: production`;
- `concurrency: { group: deploy-production, cancel-in-progress: false }`, a deploy is
  never cut in the middle of a migration;
- `timeout-minutes: 15`;
- checkout, `shivammathur/setup-php` with the runtime version, `php -l` on every
  versioned PHP file;
- Vite build in Actions with the package manager detected from the lockfile, and
  `public/build` appended to the `git archive` package;
- SSH configured from secrets and variables (`IdentitiesOnly`, `StrictHostKeyChecking yes`,
  `BatchMode yes`), **no `ssh-keyscan`**;
- `scp` of the package, then `ssh deploy-target "DEPLOY_PATH=... bash -s -- <id>" < deploy/release.sh`,
  so the script is versioned and never stale on the server;
- optional health check (`HEALTHCHECK_URL` variable);
- key removal with `if: always()`.

What you must adapt:

- `PHP_VERSION` (same as `PHP_BIN` in `release.sh`);
- branch name if not `main`;
- remove the Node steps if there is no front-end build, set `node-version`;
- enable the tests step only if the suite is fast and isolated (no network, no shared
  database). Inspect the tests before enabling them;
- if `.gitattributes` uses `export-ignore`, make sure nothing needed at runtime is excluded.

## Phase 4: credentials

Use `scripts/setup-deploy-key.sh`, or follow the same steps by hand:

1. Generate an ed25519 key in a temporary local directory:
   `ssh-keygen -t ed25519 -N '' -C 'github-actions-deploy@<org>/<repo>'`.
2. Append it to `~<deploy_user>/.ssh/authorized_keys`:
   - prefix `restrict` (no pty, no forwarding, `scp` and commands still work);
   - backup first (`authorized_keys.bak-<date>`), idempotent write (`grep -qF` before `>>`);
   - owner `<deploy_user>`, mode 600.
3. Get the host key **through the trusted channel** (the existing root SSH), reading
   `/etc/ssh/ssh_host_ed25519_key.pub`. Build the known_hosts line `<ip> ssh-ed25519 AAAA...`.
   With a port other than 22, use `[<ip>]:<port> ...`.
4. Test before touching GitHub: connect with the new key, `StrictHostKeyChecking=yes` and the
   built known_hosts, and check `whoami`, write access to `releases/`, and
   `supervisorctl status` (or `php artisan --version`).
5. On GitHub, with the account that has access to the repo (with several `gh` accounts use
   `GH_TOKEN=$(gh auth token -u <account>)`):
   - `gh api -X PUT repos/<org>/<repo>/environments/production`;
   - secrets: `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`;
   - variables: `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `DEPLOY_PATH`.
6. Delete the local private key. It only exists in the secret.

The script asks for confirmation before step 5. It is interactive, so a human may need to
run it (`! bash scripts/setup-deploy-key.sh` in Claude Code).

## Phase 5: documentation and pull request

- Add a Deploy section to the project README from `templates/README-deploy.md`: flow,
  server layout, secrets and variables table, manual rollback.
- Update specs and `CLAUDE.md`/`AGENTS.md` of the project if they exist.
- Open a PR (do not merge) using `templates/PULL_REQUEST.md`, with:
  - the table "old hook -> new step";
  - what was already configured outside the code (server and GitHub);
  - intentional differences (PHP version, chown scope, permissions before activation);
  - risks found in Phase 1;
  - an explicit warning that **merging triggers the first deploy, with migrations in
    production**.
- Do not remove the old deployer or its secret. List both as post-validation steps,
  together with disabling the old deployer, so there is never a double deploy.

## Validation that does not need a deploy

- `bash -n deploy/release.sh deploy/rollback.sh` and `shellcheck` if available.
- Parse the workflow YAML (for example `ruby -ryaml -e 'YAML.load_file(ARGV[0])' .github/workflows/deploy.yml`,
  or `actionlint` if installed).
- SSH login with the new key plus permission checks, as in Phase 4.
- **Do not** run `workflow_dispatch` or `release.sh` on the server without authorization:
  both apply migrations in production.

## Known pitfalls

- The server `/usr/bin/php` may be a different version from FPM and the workers.
- `ln -s` pointing at an existing directory creates a nested link: `rm -rf` first.
- Supervisor requires root unless the socket gives access to the deploy user's group.
- `chown` on the whole base fails without root: limit it to the release.
- A very old active release means the previous deploy was broken: report it. The first
  new deploy will ship everything accumulated on `main`.
- A user SSH key on the server (access to every repo of that account): recommend replacing
  it with a read-only deploy key, or removing it. The `git archive` + `scp` flow does not
  need the server to reach GitHub at all.
- A failure after migrations but before activation leaves the database migrated and the
  old code live. This is safe only with backward compatible migrations.
- `current` as a real directory (first migration from a non-release layout) blocks the
  swap. Moving it is a server change: ask first.
