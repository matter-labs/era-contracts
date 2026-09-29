#!/usr/bin/env bash
# Fetches one commit of a GitHub repository into DIR with plain git and checks
# out only PATH (sparse, blobs on demand). The broadcast job uses it instead of
# actions/checkout, so that no third-party code runs next to the key.
#
#   git-fetch.sh <owner/repo> <commit> <file path> <dir>
#
# GH_TOKEN (the job's GITHUB_TOKEN), when set, reaches git through its
# environment (GIT_CONFIG_*), never argv, and is not written to .git/config.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd git

[ "$#" -eq 4 ] || die "usage: git-fetch.sh <owner/repo> <commit> <file path> <dir>"
repo="$1"
sha="$2"
path="$3"
dir="$4"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must be owner/name, got: '$repo'"
validate_commit "$sha"
validate_source_path "$path"
[ ! -e "$dir" ] || die "$dir already exists"

if [ -n "${GH_TOKEN:-}" ]; then
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi
git init -q "$dir"
git -C "$dir" remote add origin "https://github.com/$repo.git"
git -C "$dir" sparse-checkout set --no-cone "$path"
git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$sha"
git -C "$dir" -c advice.detachedHead=false checkout -q "$sha"
[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "checked out $(git -C "$dir" rev-parse HEAD), expected $sha"
log "fetched $path at $sha"
