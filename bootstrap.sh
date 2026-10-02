#!/usr/bin/env bash
# One-shot setup for a fresh container/VM: git identity + SSH key for GitHub, gh CLI.
# Options for the individual steps are passed through env vars (see README.md).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

info "Step 1/2: git identity and SSH key for GitHub"
"$DIR/setup-ssh.sh"

info "Step 2/2: GitHub CLI"
"$DIR/setup-gh.sh"

cat <<MSG

All set. To protect a repository's main and development branches:

  $DIR/protect-repo.sh OWNER/REPO --dry-run   # preview
  $DIR/protect-repo.sh OWNER/REPO             # apply
MSG
