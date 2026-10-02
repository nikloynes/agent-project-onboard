#!/usr/bin/env bash
# Install the GitHub CLI (gh) if missing, then log in.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Pin a version for reproducibility (tarball install only), e.g. GH_VERSION=2.62.0
GH_VERSION="${GH_VERSION:-latest}"
GH_INSTALL_DIR="${GH_INSTALL_DIR:-$HOME/.local/bin}"
FORCE_TARBALL=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--tarball]

  --tarball   Skip the package manager and install the release binary into
              \$GH_INSTALL_DIR (default: $GH_INSTALL_DIR). No root needed.

Env: GH_VERSION (default: latest), GH_INSTALL_DIR
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --tarball) FORCE_TARBALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

install_gh_apt() {
  info "Installing gh from the official apt repository"
  local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  as_root mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | as_root tee "$keyring" >/dev/null
  as_root chmod go+r "$keyring"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
    | as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  as_root apt-get update -qq
  as_root apt-get install -y gh
}

install_gh_tarball() {
  local arch version tarball base tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv6l|armv7l) arch=armv6 ;;
    i?86) arch=386 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  version=$GH_VERSION
  if [[ $version == latest ]]; then
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)
    version=${version##*/v}
  fi
  version=${version#v}

  info "Installing gh $version ($arch) into $GH_INSTALL_DIR"
  base="https://github.com/cli/cli/releases/download/v$version"
  tarball="gh_${version}_linux_${arch}.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL --retry 3 -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/gh_${version}_checksums.txt"
  (cd "$tmp" && grep " $tarball\$" checksums.txt | sha256sum -c --quiet -) || die "Checksum mismatch for $tarball"

  tar -xzf "$tmp/$tarball" -C "$tmp"
  mkdir -p "$GH_INSTALL_DIR"
  install -m 755 "$tmp/gh_${version}_linux_${arch}/bin/gh" "$GH_INSTALL_DIR/gh"

  if [[ ":$PATH:" != *":$GH_INSTALL_DIR:"* ]]; then
    warn "$GH_INSTALL_DIR is not on your PATH. Add this to your shell rc:"
    warn "  export PATH=\"$GH_INSTALL_DIR:\$PATH\""
    export PATH="$GH_INSTALL_DIR:$PATH"
  fi
}

# 1. Install ------------------------------------------------------------------
if have gh && ! $FORCE_TARBALL; then
  ok "gh already installed: $(gh --version | head -1)"
elif [[ $(uname -s) == Darwin ]]; then
  have brew || die "Install Homebrew first, or see https://github.com/cli/cli#installation"
  brew install gh
elif ! $FORCE_TARBALL && have apt-get && { [[ $EUID -eq 0 ]] || have sudo; }; then
  install_gh_apt
else
  install_gh_tarball
fi
ok "$(gh --version | head -1)"

# 2. Authenticate ---------------------------------------------------------------
if gh auth status -h github.com >/dev/null 2>&1; then
  ok "Already logged in to GitHub:"
  gh auth status -h github.com
else
  cat <<MSG

Next: log in to GitHub with

    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key

Choose "Login with a web browser". On a headless box gh prints a one-time code;
open https://github.com/login/device on any machine and enter it.

MSG
  if [[ -t 0 ]] && confirm "Run 'gh auth login' now?" y; then
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key
    gh auth status -h github.com
  else
    warn "Skipped login. Run the command above when you're ready."
    exit 0
  fi
fi

gh config set git_protocol ssh --host github.com
ok "gh will use SSH for git operations."
