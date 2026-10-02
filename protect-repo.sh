#!/usr/bin/env bash
# Protect a repo's main and development branches with a GitHub ruleset:
#   - changes only via pull request (no direct pushes, force-pushes or deletion)
#   - at least N approvals, one of which must come from a code owner
#   - CODEOWNERS lists the project admins, so an admin must approve every PR
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO=""
MAIN_BRANCH=main
DEV_BRANCH=development
APPROVALS=1
ADMINS=""
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
  --admins A,B         Who must approve (users, or org/team). Default: the repo's
                       admin collaborators
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
    --admins) ADMINS=$2; shift 2 ;;
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
have gh || die "gh not found. Run ./setup-gh.sh first."
gh auth status -h github.com >/dev/null 2>&1 || die "Not logged in. Run: gh auth login"

if [[ -z $REPO ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "Not inside a GitHub repo. Pass OWNER/REPO."
fi
info "Repository: $REPO"
$DRY_RUN && warn "Dry run: nothing will be changed."

branch_sha() { gh api "repos/$REPO/git/ref/heads/$1" -q .object.sha 2>/dev/null; }

# 1. Branches -------------------------------------------------------------------
main_sha=$(branch_sha "$MAIN_BRANCH") \
  || die "Branch '$MAIN_BRANCH' not found. Push an initial commit to it first."
ok "Branch $MAIN_BRANCH exists"

if branch_sha "$DEV_BRANCH" >/dev/null; then
  ok "Branch $DEV_BRANCH exists"
elif $DRY_RUN; then
  info "[dry-run] would create $DEV_BRANCH from $MAIN_BRANCH ($main_sha)"
else
  gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$DEV_BRANCH" -f sha="$main_sha" >/dev/null
  ok "Created $DEV_BRANCH from $MAIN_BRANCH"
fi

# 2. CODEOWNERS: the admins who must approve --------------------------------------
# This must happen before the ruleset is active, otherwise the commit is blocked.
if $WRITE_CODEOWNERS; then
  if [[ -z $ADMINS ]]; then
    ADMINS=$(gh api --paginate "repos/$REPO/collaborators?permission=admin&affiliation=all" \
      -q '.[] | select(.type == "User") | .login' | paste -sd, -)
  fi
  [[ -n $ADMINS ]] || die "No admins found. Pass --admins user1,user2"

  owners=""
  IFS=, read -ra admin_list <<<"$ADMINS"
  for a in "${admin_list[@]}"; do
    a=${a// /}
    [[ -n $a ]] && owners+=" @${a#@}"
  done
  info "Admins who must approve:$owners"

  codeowners=$(printf '%s\n' \
    "# Managed by protect-repo.sh. A PR into a protected branch needs approval" \
    "# from at least one of these owners." \
    "*$owners")

  for branch in "$MAIN_BRANCH" "$DEV_BRANCH"; do
    path="repos/$REPO/contents/.github/CODEOWNERS"
    current=$(gh api "$path?ref=$branch" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
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
          -f message="chore: set CODEOWNERS so admins approve PRs"
          -f content="$(printf '%s\n' "$codeowners" | base64 | tr -d '\n')")
    sha=$(gh api "$path?ref=$branch" -q .sha 2>/dev/null || true)
    [[ -n $sha ]] && args+=(-f sha="$sha")
    gh api "${args[@]}" >/dev/null \
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

existing_id=$(gh api "repos/$REPO/rulesets?includes_parents=false" \
  -q ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)

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
if ! out=$(gh api -X "$method" "$endpoint" --input - <<<"$ruleset" 2>&1); then
  echo "$out" >&2
  [[ $out == *"Upgrade to GitHub Pro"* || $out == *"403"* ]] \
    && warn "Rulesets on private repos need GitHub Pro/Team (or make the repo public)."
  die "Failed to apply ruleset."
fi
id=$(jq -r .id <<<"$out" 2>/dev/null || echo "${existing_id:-?}")
ok "Ruleset '$RULESET_NAME' (id $id) is active on $MAIN_BRANCH and $DEV_BRANCH"

cat <<MSG

Verify with:
  gh ruleset view $id --repo $REPO
  gh ruleset check $MAIN_BRANCH --repo $REPO
  https://github.com/$REPO/settings/rules/$id
MSG
