# Human guide

Step by step setup of the deploy without an AI agent. The [playbook](../PLAYBOOK.md) has
the same phases with more detail on what to check.

## 0. Requirements

On the server:

- a deploy user without sudo, member of the web server group (`www-data` on Debian and
  Ubuntu);
- the versioned PHP CLI used by PHP-FPM (`php8.3`, for example) and Composer;
- Nginx `root` pointing to `<base>/current/public`;
- root access for you, only for the preparation.

On your machine: `ssh`, `ssh-keygen` and `gh` logged in with an account that has admin
access to the repository.

## 1. Audit the server

```bash
ssh root@203.0.113.10 "BASE=/var/www/example.com DEPLOY_USER=deploy PHP_VERSION=8.3 bash -s" < scripts/audit-server.sh | less
```

Write down:

- whether `current` already is a symlink to `releases/<id>`, and the date of the active
  release (very old means the last deploys were failing);
- what lives in `shared/` and which links each release has;
- the hooks of the current deployer, in order. The new script must reproduce them;
- PHP-FPM version and socket, and whether `/usr/bin/php` is the same version;
- supervisor programs, their `directory=` and `user=`, and whether the socket is
  accessible by the deploy user's group;
- whether Nginx uses `$realpath_root` in `SCRIPT_FILENAME` and `DOCUMENT_ROOT`;
- any SSH key of the deploy user that logs into GitHub as a person (`Hi <account>`).

If `shared/` does not exist yet, create it as the deploy user and move the production
`.env` there:

```bash
sudo -u deploy mkdir -p /var/www/example.com/shared /var/www/example.com/releases
sudo -u deploy cp /path/to/production/.env /var/www/example.com/shared/.env
```

## 2. Add the files to the Laravel project

```bash
mkdir -p deploy .github/workflows
cp templates/deploy/release.sh templates/deploy/rollback.sh deploy/
cp templates/.github/workflows/deploy.yml .github/workflows/
chmod +x deploy/*.sh
```

Edit:

- `deploy/release.sh`, the `CONFIG` block: `PHP_BIN`, `QUEUE_MODE`,
  `SUPERVISOR_PROGRAMS`, `KEEP_RELEASES`, and the `CUSTOMIZE` markers for extra shared
  paths or old hooks;
- `deploy/rollback.sh`: the same `PHP_BIN`, `QUEUE_MODE` and `SUPERVISOR_PROGRAMS`;
- `.github/workflows/deploy.yml`: `PHP_VERSION`, Node steps (remove them if there is no
  front-end build), tests step.

Check the syntax:

```bash
bash -n deploy/release.sh deploy/rollback.sh
shellcheck deploy/*.sh   # if installed
```

## 3. Nginx and OPcache (needs sudo)

Compare your vhost with `templates/nginx/laravel-realpath.conf`. If it uses
`$document_root` in `SCRIPT_FILENAME`, change both params to `$realpath_root` and reload
Nginx. Without this, PHP-FPM may keep serving the old release from OPcache until it is
reloaded.

If you cannot change Nginx, the alternative is `opcache.validate_timestamps=1` in the FPM
pool (default in most distributions) or reloading PHP-FPM after each deploy, which needs a
sudo rule.

## 4. Credentials

Automated, asks before touching GitHub and deletes the private key at the end:

```bash
ROOT_ALIAS=myserver HOST=203.0.113.10 PORT=22 DEPLOY_USER=deploy \
DEPLOY_PATH=/var/www/example.com REPO=org/repo PHP_BIN=php8.3 \
bash scripts/setup-deploy-key.sh
```

By hand:

```bash
# 1. key in a temporary directory
tmp="$(mktemp -d)"
ssh-keygen -t ed25519 -N '' -C 'github-actions-deploy@org/repo' -f "$tmp/deploy_key"

# 2. authorize it for the deploy user, with "restrict"
pub="$(cat "$tmp/deploy_key.pub")"
ssh myserver "cp -p ~deploy/.ssh/authorized_keys ~deploy/.ssh/authorized_keys.bak-\$(date +%Y%m%d) 2>/dev/null; \
  grep -qF '$(awk '{print $2}' "$tmp/deploy_key.pub")' ~deploy/.ssh/authorized_keys 2>/dev/null \
  || echo 'restrict $pub' >> ~deploy/.ssh/authorized_keys; \
  chown deploy: ~deploy/.ssh/authorized_keys; chmod 600 ~deploy/.ssh/authorized_keys"

# 3. host key through the trusted channel (port 22; otherwise use [ip]:port)
echo "203.0.113.10 $(ssh myserver cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')" > "$tmp/known_hosts"

# 4. test exactly like GitHub Actions will
ssh -F /dev/null -i "$tmp/deploy_key" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" \
  deploy@203.0.113.10 'whoami; test -w /var/www/example.com/releases && echo writable'

# 5. GitHub
gh api -X PUT repos/org/repo/environments/production
gh secret set DEPLOY_SSH_KEY --repo org/repo --env production < "$tmp/deploy_key"
gh secret set DEPLOY_KNOWN_HOSTS --repo org/repo --env production < "$tmp/known_hosts"
gh variable set DEPLOY_HOST --repo org/repo --env production --body 203.0.113.10
gh variable set DEPLOY_PORT --repo org/repo --env production --body 22
gh variable set DEPLOY_USER --repo org/repo --env production --body deploy
gh variable set DEPLOY_PATH --repo org/repo --env production --body /var/www/example.com

# 6. the private key only lives in the secret now
rm -rf "$tmp"
```

Optional: set `HEALTHCHECK_URL` as a variable to make the workflow fail if the site does
not answer after the deploy. You can also add required reviewers to the `production`
environment in the repository settings, so each deploy waits for an approval.

## 5. Documentation and pull request

- Paste `templates/README-deploy.md` into the project README and fill it in.
- Open a PR with `templates/PULL_REQUEST.md` as the body.
- **Merging the PR is the first deploy and runs migrations in production.** Merge when
  someone can watch it.

## 6. After the first successful deploy

1. Disable the old deployer (Envoyer, Forge, Ploi, Deployer) so it does not deploy in
   parallel.
2. Remove its SSH key from the server and its secret from GitHub.
3. Remove legacy releases that do not follow the `YYYYMMDDHHMMSS-<sha7>` format, the
   retention step ignores them.
4. If the deploy user had a personal GitHub key, remove it. This flow does not need the
   server to reach GitHub.

## Rollback

From your machine, logged in as the deploy user with your own key (the GitHub Actions key
only exists in the secret):

```bash
# previous release
ssh deploy@203.0.113.10 "DEPLOY_PATH='/var/www/example.com' bash -s" < deploy/rollback.sh
# specific release
ssh deploy@203.0.113.10 "DEPLOY_PATH='/var/www/example.com' bash -s -- '20261106120000-abc1234'" < deploy/rollback.sh
```

By hand, on the server:

```bash
cd /var/www/example.com
ls releases/
ln -sfn releases/<id> current.new && mv -Tf current.new current
cd current && php8.3 artisan queue:restart
```

Migrations are not reverted. Rolling back code is safe because migrations are backward
compatible.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Host key verification failed` in Actions | `DEPLOY_KNOWN_HOSTS` has the wrong host format, use `[ip]:port` when the port is not 22 |
| `Permission denied (publickey)` | key missing in `authorized_keys`, wrong owner or mode, or wrong `DEPLOY_USER` |
| `package not found` | `scp` wrote to another path, check `DEPLOY_PATH` and that `releases/` exists |
| `storage/storage` link inside the release | an old script used `ln -s` without `rm -rf` first |
| Composer `platform_check` error | Composer ran with a different PHP version, check `PHP_BIN` |
| Old code still served after deploy | Nginx uses `$document_root` and OPcache keeps old paths, see step 3 |
| `supervisorctl: permission denied` | supervisor socket not accessible by the deploy user's group |
| `chown: Operation not permitted` | deploy user is not in `www-data`, or files in the release belong to another user |
