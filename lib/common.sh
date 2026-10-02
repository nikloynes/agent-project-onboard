# Shared helpers. Source this file; do not execute it.

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# confirm "Question?" [y|n] -- returns the default when stdin is not a TTY.
confirm() {
  local question=$1 default=${2:-y} hint answer
  [[ $default == y ]] && hint="Y/n" || hint="y/N"
  if [[ ! -t 0 ]]; then
    [[ $default == y ]]
    return
  fi
  read -rp "$question [$hint] " answer
  [[ ${answer:-$default} =~ ^[Yy] ]]
}

# Run a command as root, via sudo if needed. Fails if neither is possible.
as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 1
  fi
}

# Make sure git user.name and user.email are set globally. Values come from
# $GIT_NAME / $GIT_EMAIL, the existing config, or a prompt (in that order).
ensure_git_identity() {
  have git || die "git is not installed."
  local key env_var value
  for key in user.name user.email; do
    env_var=GIT_NAME
    [[ $key == user.email ]] && env_var=GIT_EMAIL
    value=${!env_var:-$(git config --global "$key" || true)}
    while [[ -z $value && -t 0 ]]; do
      read -rp "git $key (not set yet): " value
    done
    if [[ -n $value ]]; then
      git config --global "$key" "$value"
      ok "git $key = $value"
    else
      warn "git $key is not set. Set it with: git config --global $key '...'"
    fi
  done
  git config --global init.defaultBranch main
}
