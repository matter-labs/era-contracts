#!/usr/bin/env bash
# Fetches one commit of a public GitHub repository into DIR with plain,
# anonymous git and checks out only PATH (sparse, blobs on demand), after
# check-on-branch.sh has confirmed the commit is on BRANCH of that repository.
# The action-free jobs use it instead of actions/checkout.
#
#   git-fetch.sh <owner/repo> <branch> <commit> <file path> <dir>

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd git

[ "$#" -eq 5 ] || die "usage: git-fetch.sh <owner/repo> <branch> <commit> <file path> <dir>"
repo="$1"
branch="$2"
sha="$3"
path="$4"
dir="$5"
validate_source_path "$path"
[ ! -e "$dir" ] || die "$dir already exists"
"$(dirname "$0")/check-on-branch.sh" "$repo" "$branch" "$sha"

git init -q "$dir"
git -C "$dir" remote add origin "https://github.com/$repo.git"
git -C "$dir" sparse-checkout set --no-cone "$path"
git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$sha"
git -C "$dir" -c advice.detachedHead=false checkout -q "$sha"
[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "checked out $(git -C "$dir" rev-parse HEAD), expected $sha"
log "fetched $path at $sha"
