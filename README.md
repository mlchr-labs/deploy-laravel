# deploy-laravel

Template for continuous deploy of an existing Laravel project to a VPS, using GitHub
Actions over SSH and atomic releases (releases + symlink, the Envoyer/Deployer model).
No external service, no agent on the server, no server access to GitHub.

It is written to be read by an AI agent, which adapts it to your project, and by people,
who can follow the same steps by hand.

## How it works

```text
push to main
  └─ GitHub Actions
       ├─ php -l, optional tests
       ├─ Vite build (public/build)
       ├─ git archive + public/build  ->  <YYYYMMDDHHMMSS>-<sha7>.tar.gz
       ├─ scp package  ->  <base>/releases/
       └─ ssh: bash -s < deploy/release.sh
             ├─ extract into releases/<id>
             ├─ link shared/.env and shared/storage
             ├─ composer install --no-dev (runtime PHP)
             ├─ storage:link, migrate --force, optimize
             ├─ permissions on the release
             ├─ current.new -> releases/<id>, mv -Tf current.new current   (atomic)
             ├─ queue:restart / horizon:terminate / supervisorctl restart
             └─ keep the last N releases
```

Server layout:

```text
/var/www/example.com/
├── current -> releases/20261106120000-abc1234    (Nginx root: current/public)
├── releases/
└── shared/
    ├── .env
    └── storage/
```

## Using it with an AI agent

Open the Laravel project in your agent (Claude Code, Codex, Cursor or similar) and send
something like:

```text
Set up the deploy of this project following
https://github.com/mlchr-labs/deploy-laravel/blob/main/PLAYBOOK.md
(clone the repo into a temporary directory to use the templates and scripts).

Repository: org/repo, branch main
Root SSH alias: myserver
Host / port: 203.0.113.10 / 22
Deploy user: deploy
Document root: /var/www/example.com
PHP: 8.3
Queues: supervisor, program "example-worker"
Front-end: Vite, yes
gh account: my-account
```

Before that, decide how the agent gets SSH access: see
[docs/ai-ssh-access.md](docs/ai-ssh-access.md). The agent works inside a fixed scope: it
does not change Nginx, PHP-FPM, supervisor, sudoers or the database, does not run
migrations or the workflow, and does not merge. It opens a PR and stops.

## Doing it by hand

Follow [docs/human-guide.md](docs/human-guide.md).

## Contents

| Path | What it is |
|---|---|
| [`PLAYBOOK.md`](PLAYBOOK.md) | Full instructions for an AI agent, phase by phase |
| [`docs/human-guide.md`](docs/human-guide.md) | Same flow, step by step for people, with troubleshooting |
| [`docs/ai-ssh-access.md`](docs/ai-ssh-access.md) | How to give (and revoke) SSH and GitHub access to an agent |
| [`templates/deploy/release.sh`](templates/deploy/release.sh) | Server side release script, goes to `deploy/release.sh` |
| [`templates/deploy/rollback.sh`](templates/deploy/rollback.sh) | Manual rollback, goes to `deploy/rollback.sh` |
| [`templates/.github/workflows/deploy.yml`](templates/.github/workflows/deploy.yml) | GitHub Actions workflow |
| [`templates/README-deploy.md`](templates/README-deploy.md) | Deploy section for the project README |
| [`templates/PULL_REQUEST.md`](templates/PULL_REQUEST.md) | PR body, with the "old hook -> new step" table |
| [`templates/nginx/laravel-realpath.conf`](templates/nginx/laravel-realpath.conf) | Reference vhost using `$realpath_root` |
| [`templates/supervisor/laravel-worker.conf`](templates/supervisor/laravel-worker.conf) | Reference worker and socket permissions |
| [`scripts/audit-server.sh`](scripts/audit-server.sh) | Read-only server audit (Phase 1) |
| [`scripts/setup-deploy-key.sh`](scripts/setup-deploy-key.sh) | Deploy key, known_hosts, test and GitHub setup (Phase 4) |

## Requirements

- Ubuntu or Debian server with GNU coreutils (`mv -T`, `find -printf`), bash 4.4 or newer.
- Versioned PHP CLI matching PHP-FPM (`php8.3`) and Composer 2 on the server.
- A deploy user without sudo, member of `www-data`.
- Nginx serving `<base>/current/public`, ideally with `$realpath_root`.
- `gh` CLI with admin access to the target repository.

## Design choices

- **Package built in Actions, not on the server.** The server never pulls from GitHub, so
  it needs no GitHub credential at all.
- **Script streamed on every deploy.** `deploy/release.sh` lives in the project repo and is
  sent over SSH each time, there is no stale copy on the server.
- **Host key pinned in a secret.** No `ssh-keyscan`, which would trust whoever answers first.
- **Deploy key with `restrict`.** No pty, no forwarding, commands and `scp` only.
- **Migrations before the swap.** The old code keeps serving while they run, so they must
  be backward compatible. Rollback only moves the symlink.
- **Concurrency without cancellation.** Two pushes queue up, a running migration is never
  interrupted.

## Authorship

Written by Fausto in pair with Claude (model Claude Opus 5.5, `claude-opus-5-5`), through
Claude Code.
