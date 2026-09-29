#!/usr/bin/env bash
# Refuses a commit that is not on a branch of the repository itself.
#
#   check-on-branch.sh <owner/repo> <branch> <commit>
#
# GitHub serves any commit of a fork network through the parent repository
# ("impostor commits"): `git fetch <parent> <sha>` and `uses: <parent>@<sha>`
# both accept a SHA that only exists in someone's fork. So the commit must be
# an ancestor of (or equal to) the named branch, which the public compare API
# answers without a token: compare/<branch>...<sha> is "behind" or "identical".

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd curl jq

[ "$#" -eq 3 ] || die "usage: check-on-branch.sh <owner/repo> <branch> <commit>"
repo="$1"
branch="$2"
sha="$3"
validate_repo "$repo"
validate_branch "$branch"
validate_commit "$sha"

status="$(curl --fail --silent --show-error --location --proto '=https' --retry 3 \
  "https://api.github.com/repos/$repo/compare/$branch...$sha" | jq -r '.status // "unknown"')" ||
  die "cannot compare $sha with $repo branch $branch (unknown commit or branch, or the API is unavailable)"
case "$status" in
  behind | identical) log "$sha is on $repo branch $branch ($status)" ;;
  *) die "$sha is not on $repo branch $branch (compare says '$status'); only commits of upstream branches are accepted" ;;
esac
