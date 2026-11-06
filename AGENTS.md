# Agent instructions

This repository is a **template**, not an application. Nothing here is deployed.

- Asked to set up deploy in a Laravel project: follow [PLAYBOOK.md](PLAYBOOK.md). Work in
  the target project, copy files from `templates/` and adapt them there.
- Asked to change this template: keep the playbook, the human guide, the templates and the
  scripts consistent with each other. A behavior change in `release.sh` must be reflected
  in `PLAYBOOK.md`, `docs/human-guide.md` and `templates/README-deploy.md`.

Conventions:

- English everywhere.
- Prose for humans uses commas and periods, no em dashes.
- Shell: bash, `set -Eeuo pipefail`, validate every input that ends up in a path or a
  remote command, never print secrets. Run `bash -n` and `shellcheck` before committing.
- Placeholders use documentation ranges: `203.0.113.10`, `198.51.100.7`, `example.com`,
  `org/repo`, user `deploy`.
