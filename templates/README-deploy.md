## Deploy

Every push to `main` deploys to production through GitHub Actions
(`.github/workflows/deploy.yml`). It can also be started by hand from the Actions tab
(`workflow_dispatch`). Deploys never run in parallel and are never cancelled midway.

### Flow

1. Actions checks out the code, lints PHP files and builds the front-end assets.
2. It packages the commit with `git archive` (plus `public/build`) as
   `<YYYYMMDDHHMMSS>-<sha7>.tar.gz`.
3. It uploads the package to the server with `scp` and streams `deploy/release.sh` over
   SSH.
4. On the server, `release.sh` extracts the release, links `.env` and `storage`, runs
   `composer install`, `migrate --force` and `optimize`, then swaps the `current` symlink
   atomically and restarts the queue workers.

If anything fails before the swap, the new release is removed and the site keeps running
the previous one.

### Server layout

```text
/var/www/example.com/              <- DEPLOY_PATH
├── current -> releases/<id>       <- Nginx root: current/public
├── releases/
│   ├── 20261106120000-abc1234/
│   └── ...                        <- last 5 kept
└── shared/
    ├── .env                       <- production config, never in git
    └── storage/                   <- persistent files and logs
```

### Configuration (GitHub environment `production`)

| Name | Type | Value |
|---|---|---|
| `DEPLOY_SSH_KEY` | secret | Private ed25519 key, authorized with `restrict` for the deploy user |
| `DEPLOY_KNOWN_HOSTS` | secret | Server host key line, `[ip]:port ssh-ed25519 ...` when the port is not 22 |
| `DEPLOY_HOST` | variable | Server IP or host |
| `DEPLOY_PORT` | variable | SSH port |
| `DEPLOY_USER` | variable | Deploy user |
| `DEPLOY_PATH` | variable | Deploy base, e.g. `/var/www/example.com` |
| `HEALTHCHECK_URL` | variable, optional | URL checked after the deploy |

Runtime settings (PHP binary, queue mode, supervisor programs, releases kept) live in the
`CONFIG` block of `deploy/release.sh`.

### Migrations

Migrations run **before** the swap, while the previous release is still serving traffic.
They must be backward compatible (expand/contract): add first, remove only in a later
deploy, after no running code depends on the old structure.

### Rollback

```bash
# previous release
ssh deploy@<host> "DEPLOY_PATH='/var/www/example.com' bash -s" < deploy/rollback.sh
# specific release
ssh deploy@<host> "DEPLOY_PATH='/var/www/example.com' bash -s -- '<release_id>'" < deploy/rollback.sh
```

Manual equivalent, on the server:

```bash
cd /var/www/example.com
ln -sfn releases/<id> current.new && mv -Tf current.new current
cd current && php8.3 artisan queue:restart
```

Migrations are not reverted, which is why they must be backward compatible.
