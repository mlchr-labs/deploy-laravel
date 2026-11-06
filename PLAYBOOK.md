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

