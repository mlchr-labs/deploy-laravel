## Deploy via GitHub Actions (atomic releases)

Replaces <old deployer> with a GitHub Actions workflow that deploys over SSH using
releases + symlink. The server script is versioned in `deploy/release.sh` and sent on
every deploy.

> **Warning: merging this PR triggers the first deploy, including `migrate --force` in
> production.** It will ship everything accumulated on `main` since <date of the active
> release>. Merge when someone can watch the run.

### Old hook -> new step

| # | Old hook (<old deployer>) | New step (`deploy/release.sh`) |
|---|---|---|
| 1 | Clone / download | `git archive` in Actions + `scp` + `tar -xzf` |
| 2 | Link `.env` | `ln -sfn shared/.env release/.env` |
| 3 | Link `storage` | `rm -rf release/storage && ln -sfn shared/storage release/storage` |
| 4 | `composer install --no-dev` | `php8.3 /usr/bin/composer install --no-dev --optimize-autoloader ...` |
| 5 | `npm run build` | Built in Actions, `public/build` added to the package |
| 6 | `php artisan migrate --force` | Same, before activation |
| 7 | `php artisan optimize` | Same, before activation |
| 8 | Activate | `ln -sfn` + `mv -Tf` (atomic) |
| 9 | `php artisan queue:restart` | Same, plus `supervisorctl restart '<program>:*'` |
| 10 | Purge old releases | Keeps the last 5, never the active one |

### Already configured outside the code

Server:

- [ ] Deploy key added to `~<deploy_user>/.ssh/authorized_keys` with `restrict`
      (backup at `authorized_keys.bak-<date>`)
- [ ] `shared/.env` and `shared/storage` in place
- [ ] Login with the new key tested: `whoami`, write on `releases/`, `supervisorctl status`

GitHub (environment `production`):

- [ ] Secrets `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`
- [ ] Variables `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `DEPLOY_PATH`

### Intentional differences

- PHP: uses `php<x.y>` everywhere (the old flow used `/usr/bin/php`, which is `<other version>`).
- `chown` limited to the new release, no sudo needed.
- Permissions are applied before activation, the release is never live with wrong permissions.
- <anything else>

### Risks found

- <e.g. active release from <date>, the previous deploy was failing>
- <e.g. the deploy user has a GitHub user key (`Hi <account>`), recommend removing it>
- <e.g. Nginx uses `$document_root`, OPcache may serve old code until FPM reloads>

### Validation done without deploying

- [ ] `bash -n deploy/release.sh deploy/rollback.sh`
- [ ] `shellcheck deploy/*.sh`
- [ ] Workflow YAML parsed
- [ ] SSH login with the new key and permission checks

### After the first successful deploy

- [ ] Disable <old deployer> so there is no double deploy
- [ ] Remove the old deployer key from the server and its secret from GitHub
- [ ] Remove legacy releases outside the `YYYYMMDDHHMMSS-<sha7>` format
- [ ] <remove the GitHub user key from the deploy user, if any>

### Rollback

```bash
ssh <deploy_user>@<host> "DEPLOY_PATH='<base>' bash -s" < deploy/rollback.sh
```
