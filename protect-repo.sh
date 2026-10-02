#!/usr/bin/env bash
# Protect a repo's main and development branches with a GitHub ruleset:
#   - changes only via pull request (no direct pushes, force-pushes or deletion)
#   - at least N approvals, one of which must come from a code owner
#   - CODEOWNERS lists who may approve (default: the repo's admins, or pick them
#     with --codeowners), so one of them must approve every PR
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO=""
MAIN_BRANCH=main
DEV_BRANCH=development
APPROVALS=1
CODEOWNERS=""
ADMIN_BYPASS=false
WRITE_CODEOWNERS=true
DRY_RUN=false
RULESET_NAME="protect-main-and-development"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OWNER/REPO] [options]

Defaults to the repo of the current directory.

  --main NAME          Main branch (default: $MAIN_BRANCH)
  --dev NAME           Development branch, created from main if missing (default: $DEV_BRANCH)
  --approvals N        Required approvals per PR (default: $APPROVALS)
  --codeowners A,B     Who may approve: users and/or org/team, written to
                       .github/CODEOWNERS. Each needs write access to the repo.
                       Default: the repo's admins (you're asked to confirm the list
                       when it's an org repo or has several people). Alias: --admins
  --admin-bypass       Let repo admins merge PRs without the required approval.
                       Needed on solo projects: GitHub won't let you approve your own PR
  --skip-codeowners    Don't write .github/CODEOWNERS (manage it yourself)
  --dry-run            Print what would happen; change nothing
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --main) MAIN_BRANCH=$2; shift 2 ;;
    --dev) DEV_BRANCH=$2; shift 2 ;;
    --approvals) APPROVALS=$2; shift 2 ;;
    --codeowners|--admins) CODEOWNERS=$2; shift 2 ;;
    --admin-bypass) ADMIN_BYPASS=true; shift ;;
    --skip-codeowners) WRITE_CODEOWNERS=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "Unknown option: $1" ;;
    *) REPO=$1; shift ;;
  esac
done

if ! [[ $APPROVALS =~ ^[0-9]+$ ]] || (( APPROVALS < 1 || APPROVALS > 10 )); then
  die "--approvals must be 1-10"
fi
# gh with retries for connections that never got established (flaky VM/container
# networks). Those errors happen before a request is sent, so retrying is safe even
# for writes. Any other error is printed and returned straight away.
gh_retry() {
  local attempt err rc
  err=$(mktemp)
  for attempt in 1 2 3 4; do
    gh "$@" 2>"$err" && { rm -f "$err"; return 0; }
    rc=$?
    grep -qE 'dial tcp|no such host|TLS handshake timeout' "$err" || break
    (( attempt < 4 )) && sleep $(( attempt * 2 ))
  done
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

have gh || die "gh not found. Run ./setup-gh.sh first."
gh_retry auth status -h github.com >/dev/null || die "gh is not logged in (see above). Run: gh auth login"

if [[ -z $REPO ]]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$(pwd) is not a git repository. cd into one, or pass OWNER/REPO."
  REPO=$(gh_retry repo view --json nameWithOwner -q .nameWithOwner) \
    || die "Couldn't work out the GitHub repo for $(pwd) (see above). Pass OWNER/REPO."
fi
read -r permission in_org < <(gh_retry repo view "$REPO" --json viewerPermission,isInOrganization \
  -q '.viewerPermission + " " + (.isInOrganization | tostring)') \
  || die "Can't access $REPO (see above). Check the name and that you have access."
[[ $permission == ADMIN ]] \
  || die "You need admin rights on $REPO to manage rulesets (you have: ${permission:-none})."
info "Repository: $REPO"
$DRY_RUN && warn "Dry run: nothing will be changed."

# Print a branch's commit SHA. Returns 1 if the branch doesn't exist; dies on other errors.
branch_sha() {
  local out
  if out=$(gh_retry api "repos/$REPO/git/ref/heads/$1" -q .object.sha 2>&1); then
    echo "$out"
    return 0
  fi
  [[ $out == *"HTTP 404"* ]] && return 1
  [[ $out == *"HTTP 409"* ]] && die "$REPO is empty. Push an initial commit to $MAIN_BRANCH first."
  die "Couldn't look up branch '$1' in $REPO: $out"
}

# Code owners: decide and validate before changing anything ------------------------
# Returns 1 (with a warning) if a user/team can't act as a code owner on $REPO.
check_owner() {
  local owner=$1 out
  if [[ $owner == */* ]]; then
    out=$(gh_retry api "orgs/${owner%%/*}/teams/${owner#*/}/repos/$REPO" \
      -H "Accept: application/vnd.github.v3.repository+json" -q .permissions.push 2>&1) \
      || { [[ $out == *"HTTP 404"* ]] || die "Couldn't check team @$owner: $out"
           warn "Team @$owner doesn't exist or has no access to $REPO"; return 1; }
    [[ $out == true ]] || { warn "Team @$owner has read-only access to $REPO"; return 1; }
  else
    out=$(gh_retry api "repos/$REPO/collaborators/$owner/permission" -q .permission 2>&1) \
      || { [[ $out == *"HTTP 404"* ]] || die "Couldn't check user @$owner: $out"
           warn "User @$owner doesn't exist"; return 1; }
    case $out in
      admin|maintain|write) ;;
      *) warn "@$owner has '$out' access to $REPO"; return 1 ;;
    esac
  fi
}

if $WRITE_CODEOWNERS; then
  auto_detected=false
  if [[ -z $CODEOWNERS ]]; then
    auto_detected=true
    CODEOWNERS=$(gh_retry api --paginate "repos/$REPO/collaborators?permission=admin&affiliation=all" \
      -q '.[] | select(.type == "User") | .login' | paste -sd, -)
    [[ -n $CODEOWNERS ]] || die "No admins found. Pass --codeowners user1,my-org/team"
  fi

  owner_list=()
  IFS=, read -ra entries <<<"$CODEOWNERS"
  for entry in "${entries[@]}"; do
    entry=${entry// /}
    entry=${entry#@}
    [[ -n $entry ]] && owner_list+=("$entry")
  done
  (( ${#owner_list[@]} > 0 )) || die "--codeowners is empty."

  invalid=0
  for owner in "${owner_list[@]}"; do
    check_owner "$owner" || invalid=$(( invalid + 1 ))
  done
  (( invalid == 0 )) || die "Code owners need write access to $REPO, or GitHub ignores them and PRs can't get the required approval. Fix the list above."

  owners=$(printf ' @%s' "${owner_list[@]}")
  info "Code owners who can approve:$owners"

  # Auto-detected admins in an org can include every org owner. Each code owner is
  # asked to review every PR, so make sure this list is wanted.
  if $auto_detected && [[ $in_org == true || ${#owner_list[@]} -gt 1 ]] && ! $DRY_RUN; then
    [[ -t 0 ]] || die "Found ${#owner_list[@]} admins. Pass --codeowners to say who should approve."
    confirm "Each of them will be asked to review every PR. Use this list?" n \
      || die "Aborted. Pass --codeowners user1,my-org/team to choose who approves."
  fi
fi

# 1. Branches -------------------------------------------------------------------
main_sha=$(branch_sha "$MAIN_BRANCH") \
  || die "Branch '$MAIN_BRANCH' not found. Push an initial commit to it first."
ok "Branch $MAIN_BRANCH exists"

if branch_sha "$DEV_BRANCH" >/dev/null; then
  ok "Branch $DEV_BRANCH exists"
elif $DRY_RUN; then
  info "[dry-run] would create $DEV_BRANCH from $MAIN_BRANCH ($main_sha)"
else
  gh_retry api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$DEV_BRANCH" -f sha="$main_sha" >/dev/null
  ok "Created $DEV_BRANCH from $MAIN_BRANCH"
fi

# 2. CODEOWNERS: who must approve ---------------------------------------------------
# This must happen before the ruleset is active, otherwise the commit is blocked.
if $WRITE_CODEOWNERS; then
  codeowners=$(printf '%s\n' \
    "# Managed by protect-repo.sh. A PR into a protected branch needs approval" \
    "# from at least one of these owners." \
    "*$owners")

  for branch in "$MAIN_BRANCH" "$DEV_BRANCH"; do
    path="repos/$REPO/contents/.github/CODEOWNERS"
    # Exits non-zero (404) when there's no CODEOWNERS yet.
    current=$(gh_retry api "$path?ref=$branch" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
    if [[ $current == "$codeowners" ]]; then
      ok "CODEOWNERS up to date on $branch"
      continue
    fi
    if $DRY_RUN; then
      info "[dry-run] would commit .github/CODEOWNERS to $branch:"
      sed 's/^/      /' <<<"$codeowners"
      continue
    fi
    args=(-X PUT "$path" -f branch="$branch"
          -f message="chore: set CODEOWNERS for required PR approvals"
          -f content="$(printf '%s\n' "$codeowners" | base64 | tr -d '\n')")
    sha=$(gh_retry api "$path?ref=$branch" -q .sha 2>/dev/null || true)
    [[ -n $sha ]] && args+=(-f sha="$sha")
    gh_retry api "${args[@]}" >/dev/null \
      || die "Couldn't commit CODEOWNERS to $branch. If it's already protected, change CODEOWNERS via a PR and re-run with --skip-codeowners."
    ok "Committed .github/CODEOWNERS to $branch"
  done
fi

# 3. Ruleset --------------------------------------------------------------------
bypass='[]'
# RepositoryRole 5 = admin. "pull_request" mode: admins may merge a PR without the
# required approval, but still can't push directly.
$ADMIN_BYPASS && bypass='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}]'

ruleset=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": $bypass,
  "conditions": {
    "ref_name": {"include": ["refs/heads/$MAIN_BRANCH", "refs/heads/$DEV_BRANCH"], "exclude": []}
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": $APPROVALS,
      "require_code_owner_review": true,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": false
    }}
  ]
}
JSON
)

existing_id=$(gh_retry api "repos/$REPO/rulesets?includes_parents=false" \
  -q ".[] | select(.name == \"$RULESET_NAME\") | .id") \
  || die "Couldn't list existing rulesets for $REPO (see above)."

if $DRY_RUN; then
  info "[dry-run] would ${existing_id:+update ruleset $existing_id}${existing_id:-create ruleset} with:"
  echo "$ruleset"
  exit 0
fi

if [[ -n $existing_id ]]; then
  method=PUT endpoint="repos/$REPO/rulesets/$existing_id"
else
  method=POST endpoint="repos/$REPO/rulesets"
fi
if ! id=$(gh_retry api -X "$method" "$endpoint" --input - -q .id <<<"$ruleset" 2>&1); then
  out=$id
  echo "$out" >&2
  [[ $out == *"Upgrade to GitHub Pro"* || $out == *"403"* ]] \
    && warn "Rulesets on private repos need GitHub Pro/Team (or make the repo public)."
  die "Failed to apply ruleset."
fi
ok "Ruleset '$RULESET_NAME' (id $id) is active on $MAIN_BRANCH and $DEV_BRANCH"

cat <<MSG

Verify with:
  gh ruleset view $id --repo $REPO
  gh ruleset check $MAIN_BRANCH --repo $REPO
  https://github.com/$REPO/settings/rules/$id
MSG
