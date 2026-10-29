#!/usr/bin/env bash
# Reads one transaction file at a pinned commit from a git checkout.
#
#   fetch.sh --check-only <commit> <path>
#   fetch.sh <commit> <path> <repo dir> <plan dir>
#
# <commit> is a full 40-hex SHA of the repository the workflow runs in and
# <path> a repo-relative .json file. --check-only validates the two inputs and
# nothing else (the workflow runs it before it checks the commit out).
#
# Writes <plan dir>/transactions.json (the file, byte for byte) and
# <plan dir>/source.json (repo, commit, path, git blob sha, sha256).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [ "${1:-}" = --check-only ]; then
  [ "$#" -eq 3 ] || die "usage: fetch.sh --check-only <commit> <path>"
  validate_commit "$2"
  validate_source_path "$3"
  exit 0
fi
[ "$#" -eq 4 ] || die "usage: fetch.sh <commit> <path> <repo dir> <plan dir>"
sha="$1"
path="$2"
repo_dir="$3"
out="$4"
validate_commit "$sha"
validate_source_path "$path"
require_cmd git jq

resolved="$(git -C "$repo_dir" rev-parse --verify --quiet "$sha^{commit}")" ||
  die "commit $sha is not in $repo_dir"
[ "$resolved" = "$sha" ] || die "$sha resolved to $resolved; refusing"
[ "$(git -C "$repo_dir" cat-file -t "$sha:$path" 2>/dev/null)" = blob ] ||
  die "$path is not a file at commit $sha"

mkdir -p "$out"
git -C "$repo_dir" cat-file blob "$sha:$path" >"$out/transactions.json"
blob="$(git -C "$repo_dir" rev-parse "$sha:$path")"
[ "$(git hash-object "$out/transactions.json")" = "$blob" ] || die "the extracted file does not hash to blob $blob"

# owner/name for the summary link, from the checkout's origin (git-fetch.sh
# sets it to the upstream repository; the workflow's own repository is the
# caller's, not where the file comes from).
repo="$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null |
  sed -E -e 's#^(https://|ssh://)?([^@/]*@)?github\.com[:/]##' -e 's#\.git$##' || true)"
jq -n --arg repo "${repo:-local}" --arg commit "$sha" --arg path "$path" --arg blob "$blob" \
  --arg sha256 "$(sha256_of "$out/transactions.json")" \
  '{repo: $repo, commit: $commit, path: $path, gitBlobSha: $blob, sha256: $sha256}' >"$out/source.json"
log "read $path at $sha (blob $blob)"
