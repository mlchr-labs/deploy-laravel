# Giving an AI agent SSH access to the server

The agent needs root access only during preparation (Phase 1 audit and Phase 4 key
install). After that, GitHub Actions uses a separate, restricted deploy key and the agent
access can be removed.

Pick one of the three modes below. Prefer the least access that still gets the job done.

## Mode 1: no access (human runs the commands)

The agent never touches the server. It tells you which commands to run, you run them and
paste the output back.

1. Run the audit yourself:

   ```bash
   ssh root@203.0.113.10 "BASE=/var/www/example.com DEPLOY_USER=deploy PHP_VERSION=8.3 bash -s" < scripts/audit-server.sh > audit.txt
   ```

2. Review `audit.txt`. It prints `.env` key names only, plus values that are paths, but
   check it before sharing anyway.
3. Paste it into the conversation.
4. For Phase 4, run `scripts/setup-deploy-key.sh` yourself (see the
   [human guide](human-guide.md#4-credentials)).

Safest option, a bit slower.

## Mode 2: temporary key for the agent (recommended)

The agent runs on your machine (Claude Code, Codex, Cursor or similar) and uses a
dedicated SSH key that you revoke at the end.

### 2.1 Create a dedicated key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ai_setup_ed25519 -C "ai-setup-$(date +%Y%m%d)"
```

Use a passphrase if your agent can rely on `ssh-agent`, otherwise leave it empty and
delete the key at the end.

### 2.2 Authorize it on the server, limited in time and origin

Add one line to `/root/.ssh/authorized_keys` (or to the account you use for
administration):

```text
from="198.51.100.7",expiry-time="20261231",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... ai-setup-20261106
```

- `from=` is your public IP, so the key is useless from anywhere else;
- `expiry-time=` makes sshd reject the key after that date (OpenSSH 7.7 or newer, check
  `man sshd` on the server);
- the `no-*` options keep the session to plain commands.

### 2.3 Create a local alias

In `~/.ssh/config` on your machine:

```text
Host myserver-ai
    HostName 203.0.113.10
    Port 22
    User root
    IdentityFile ~/.ssh/ai_setup_ed25519
    IdentitiesOnly yes
```

Test it: `ssh myserver-ai 'hostname && id'`.

Tell the agent: "the root SSH alias is `myserver-ai`".

### 2.4 Keep the agent on a leash

- Do not run the agent in a mode that auto-approves every shell command while it has
  root access. Approve each `ssh` call.
- In Claude Code you can force a prompt for remote commands in `.claude/settings.json`
  of the project:

  ```json
  {
    "permissions": {
      "ask": ["Bash(ssh:*)", "Bash(scp:*)", "Bash(gh secret:*)", "Bash(gh variable:*)"]
    }
  }
  ```

- Read the commands before approving. Anything with `sudoers`, `nginx`, `php-fpm`,
  `supervisor`, `systemctl`, `mysql`, `psql` or `artisan migrate` is out of scope unless
  you asked for it.

### 2.5 Revoke at the end

```bash
ssh myserver-ai "sed -i.bak '/ai-setup-20261106\$/d' /root/.ssh/authorized_keys"
rm -f ~/.ssh/ai_setup_ed25519 ~/.ssh/ai_setup_ed25519.pub
```

Then remove the `myserver-ai` block from `~/.ssh/config`.

## Mode 3: reuse your existing root alias

If you already have a root alias (for example `myserver`) and accept that the agent uses
it, just give the agent its name. Keep the precautions of 2.4. This is the quickest mode
and the one with the widest access, since the key is not limited in time.

## What the agent does with that access

| Step | Runs as | Changes something? |
|---|---|---|
| Phase 1 audit (`scripts/audit-server.sh`) | root | No |
| Install deploy public key in `~deploy/.ssh/authorized_keys` | root | Yes, with backup |
| Read `/etc/ssh/ssh_host_ed25519_key.pub` | root | No |
| Test login with the new deploy key | deploy | No |

Nothing else is in scope. Changes to Nginx, PHP-FPM, supervisor, sudoers or the database
must be requested and approved one by one.

## GitHub access for the agent

The agent needs a `gh` session with admin rights on the repository to create the
environment, secrets and variables.

- Check: `gh auth status`.
- With several accounts, the agent selects one per command:
  `GH_TOKEN="$(gh auth token -u <account>)" gh ...`.
- To pin an account to a folder, use [direnv](https://direnv.net) with an `.envrc`
  (never commit it):

  ```bash
  export GH_TOKEN="$(gh auth token -u <account>)"
  ```

  then `direnv allow`.
