# agent-project-onboard

## NOTE - this is 100% AI generated, and should be used with caution! 

Startup recipe for fresh containers/VMs: GitHub SSH access, the `gh` CLI, and
branch protection for your repos.

```
bootstrap.sh       setup-ssh.sh -> setup-gh.sh
setup-ssh.sh       git name/email, new ed25519 key, ~/.ssh/config, pinned GitHub host keys, verify
setup-gh.sh        install gh (apt / brew / release tarball), then gh auth login
protect-repo.sh    ruleset on main + development: PR-only, admin approval required
lib/common.sh      shared helpers
```

All scripts are idempotent, so re-running them is safe.

## Quick start

On a fresh machine you have no SSH key yet, so fetch the scripts over HTTPS:

```bash
git clone https://github.com/<you>/agent-project-onboard.git && cd agent-project-onboard
./bootstrap.sh
```

Non-interactive (e.g. a Dockerfile or cloud-init) via env vars:

```bash
GIT_NAME="Your Name" GIT_EMAIL="you@example.com" ./bootstrap.sh
```

When stdin is not a terminal, prompts take their defaults. `gh auth login` is
skipped, and you get the command to run later.

### setup-ssh.sh

First it makes sure git `user.name` and `user.email` are set. It takes them from
`GIT_NAME` / `GIT_EMAIL`, then from your existing git config. If neither has them,
it asks.

Then it asks for a key name. The default is `github_<hostname>`. On a re-run, the
default is the key already configured for github.com, so pressing Enter reuses it.
The name becomes the key file `~/.ssh/<name>` and its title on GitHub,
`<name> (<date>)`.

| Option / env | Default |
| --- | --- |
| `--name NAME` / `SSH_KEY_NAME` | prompt, default `github_<hostname>` |
| `--key PATH` / `SSH_KEY_PATH` | `~/.ssh/<name>` (full path; overrides `--name`) |
| `--no-passphrase` | off (ssh-keygen asks for one) |

The script fetches GitHub's host keys over HTTPS from `api.github.com/meta`,
rather than trusting whatever the first SSH connection offers. If `gh` is already
logged in, it offers to upload the key with `gh ssh-key add`. Otherwise it prints
the key and the steps for <https://github.com/settings/ssh/new>, then re-runs
`ssh -T git@github.com` until the key works. The test uses only the new key, so
another key in your agent can't make it pass by accident.

### setup-gh.sh

On Debian/Ubuntu with root or sudo, gh comes from the official apt repo. On macOS
it uses Homebrew. Otherwise, or with `--tarball`, it downloads the release binary
into `~/.local/bin`, checks the checksum, and needs no root.

To pin a version for reproducible images, set `GH_VERSION=2.62.0` (tarball install).

## Protecting a repo

Run it from inside the project's folder, and the repo is taken from the folder's
git remote:

```bash
cd ~/code/my_project
bash ~/agent-project-onboard/protect-repo.sh --dry-run   # show the plan
bash ~/agent-project-onboard/protect-repo.sh             # apply
```

Or run it from anywhere and name the repo, which can be yours or an organisation's:

```bash
./protect-repo.sh OWNER/REPO --dry-run
./protect-repo.sh my-org/my_project --admins my-org/maintainers
./protect-repo.sh OWNER/REPO --admin-bypass   # solo projects, see below
```

You need admin rights on the repo. The script checks this first, and it retries
when the connection to GitHub can't be made.

What it does:

1. Creates `development` from `main` if it doesn't exist.
2. Commits `.github/CODEOWNERS` with `* @admin1 @admin2` to both branches. By
   default these are the repo's admin collaborators. In an org that includes
   every org owner, so a team is usually better: `--admins my-org/maintainers`.
   The team needs write access to the repo.
3. Creates or updates a **repository ruleset** named
   `protect-main-and-development` on both branches:
   - no direct pushes; every change must come through a pull request
   - at least `--approvals N` approvals (default 1)
   - **one approval must be from a code owner**, which means an admin
   - new commits dismiss earlier approvals, and someone other than the last
     pusher must approve
   - no force-pushes, no branch deletion
   - no bypass by default, admins included

### How "an admin must approve" works

GitHub has no "an admin must approve" setting. The standard approach is
CODEOWNERS plus "require review from code owners": a PR can merge only once a
listed code owner has approved it. Because the script lists only admins, this
gives you "an admin must approve". Code owners need write access to the repo.

### Solo projects: use `--admin-bypass`

GitHub doesn't let you approve your own PR. If you are the only admin, the rules
above would block every PR you open. `--admin-bypass` lets repo admins merge a PR
without the approval. In `pull_request` bypass mode, admins still can't push
directly.

### Limitations

- Rulesets on **private** repos need GitHub Pro (personal accounts) or Team
  (organisations). On the Free plan they work only on public repos. The script tells you if GitHub refuses.
- After protection is on, edit CODEOWNERS through a PR, then re-run with
  `--skip-codeowners`.
- Inspect the result with `gh ruleset list`, `gh ruleset view <id>`, and
  `gh ruleset check main`.
