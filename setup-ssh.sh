#!/usr/bin/env bash
# Create an SSH key for GitHub, help register it, and verify that it works.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SSH_CONFIG="$HOME/.ssh/config"
KEY_NAME="${SSH_KEY_NAME:-}"
KEY_PATH="${SSH_KEY_PATH:-}"
PASSPHRASE_ARGS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--name NAME] [--key PATH] [--no-passphrase]

  --name NAME       Key name: file ~/.ssh/NAME and the key's title on GitHub.
                    Default: github_<hostname>, or the key already configured
                    for github.com. You're prompted unless this is given.
                    (env SSH_KEY_NAME)
  --key PATH        Full private key path; overrides --name (env SSH_KEY_PATH)
  --no-passphrase   Create the key without a passphrase (handy for throwaway VMs)

Git identity comes from GIT_NAME / GIT_EMAIL, git config, or a prompt.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) KEY_NAME=$2; shift 2 ;;
    --key) KEY_PATH=$2; shift 2 ;;
    --no-passphrase) PASSPHRASE_ARGS=(-N ""); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

have ssh-keygen || die "ssh-keygen not found (install openssh-client)."

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# 1. Git identity (also used in the key comment) ---------------------------------
ensure_git_identity
EMAIL=$(git config --global user.email || true)

# 2. Key name ---------------------------------------------------------------------
# IdentityFile already configured for github.com in ~/.ssh/config, if any.
configured_key() {
  [[ -f $SSH_CONFIG ]] || return 0
  awk 'tolower($1) == "host" { in_block = 0; for (i = 2; i <= NF; i++) if ($i == "github.com") in_block = 1 }
       in_block && tolower($1) == "identityfile" { print $2; exit }' "$SSH_CONFIG" \
    | sed "s|^~|$HOME|"
}

if [[ -z $KEY_PATH ]]; then
  existing=$(configured_key)
  if [[ -z $KEY_NAME && -n $existing ]]; then
    default_name=$(basename "$existing")
  else
    default_name="github_$(hostname -s | tr -c 'A-Za-z0-9._\n-' '-')"
  fi
  if [[ -z $KEY_NAME && -t 0 ]]; then
    read -rp "SSH key name [$default_name]: " KEY_NAME
  fi
  KEY_NAME=${KEY_NAME:-$default_name}
  [[ $KEY_NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "Key name may only contain letters, digits, '.', '_' and '-'."
  KEY_PATH="$HOME/.ssh/$KEY_NAME"
fi
KEY_NAME=$(basename "$KEY_PATH")
KEY_TITLE="$KEY_NAME ($(date +%F))"

# 3. Key pair ---------------------------------------------------------------------
if [[ -f $KEY_PATH ]]; then
  ok "Reusing existing key $KEY_PATH"
else
  info "Generating ed25519 key at $KEY_PATH"
  ssh-keygen -t ed25519 -C "${EMAIL:-$USER} ($KEY_NAME)" -f "$KEY_PATH" "${PASSPHRASE_ARGS[@]}"
fi

# 4. ~/.ssh/config: use this key for github.com --------------------------------
if grep -qE '^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?github\.com([[:space:]]|$)' "$SSH_CONFIG" 2>/dev/null; then
  if [[ $(configured_key) == "$KEY_PATH" ]]; then
    ok "$SSH_CONFIG already uses this key for github.com"
  else
    warn "$SSH_CONFIG already has a 'Host github.com' entry for another key; leaving it alone."
    warn "To use the new key, set in that entry: IdentityFile $KEY_PATH"
  fi
else
  cat >> "$SSH_CONFIG" <<CONF

Host github.com
    HostName github.com
    User git
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
CONF
  chmod 600 "$SSH_CONFIG"
  ok "Added github.com entry to $SSH_CONFIG"
fi

# 5. known_hosts: pin GitHub's host keys, fetched over HTTPS (no blind TOFU) ----
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
  ok "github.com already in $KNOWN_HOSTS"
else
  host_keys=$(curl -fsSL https://api.github.com/meta \
    | grep -oE '"(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+"' | tr -d '"') || true
  [[ -n $host_keys ]] || die "Could not fetch GitHub host keys from https://api.github.com/meta"
  sed 's/^/github.com /' <<<"$host_keys" >> "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
  ok "Added GitHub host keys to $KNOWN_HOSTS"
fi

# 6. Register the public key with GitHub ----------------------------------------
test_ssh() {
  local out
  # Test this key only: ignore other config and other keys loaded in an agent.
  out=$(ssh -T -F /dev/null -i "$KEY_PATH" -o IdentitiesOnly=yes -o ConnectTimeout=10 \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes git@github.com 2>&1 || true)
  if [[ $out == *"successfully authenticated"* ]]; then
    ok "$out"
    return 0
  fi
  warn "SSH test failed: ${out:-no output}"
  return 1
}

if test_ssh 2>/dev/null; then
  ok "This key already works with GitHub."
  exit 0
fi

uploaded=false
if have gh && gh auth status -h github.com >/dev/null 2>&1 \
   && confirm "gh is logged in. Upload the key with 'gh ssh-key add'?" y; then
  if gh ssh-key add "$KEY_PATH.pub" --title "$KEY_TITLE" --type authentication; then
    uploaded=true
  else
    warn "Upload failed. If it's a scope issue run: gh auth refresh -h github.com -s admin:public_key"
  fi
fi

if ! $uploaded; then
  cat <<MSG

Add this public key to GitHub:

  1. Open https://github.com/settings/ssh/new
  2. Title:    $KEY_TITLE
     Key type: Authentication Key
  3. Paste this into "Key":

$(cat "$KEY_PATH.pub")

MSG
fi

# 7. Verify ---------------------------------------------------------------------
if [[ ! -t 0 ]]; then
  test_ssh || die "Not authenticated yet. Add the key, then re-run this script."
  exit 0
fi
until test_ssh; do
  read -rp "Press Enter to test again once the key is added (Ctrl-C to abort)... " _
done
