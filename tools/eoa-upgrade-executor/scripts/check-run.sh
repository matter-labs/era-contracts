#!/usr/bin/env bash
# Checks who started the run and where, with no API calls. The preflight job
# runs it, and so does the broadcast job itself, because re-running a failed
# broadcast job does not re-run preflight.
#
#   - the repository is config.json's executionRepo
#   - the run is on the default branch
#   - the person who started (or re-ran) it is one of config.json's dispatchers
#
# Env: REPO, REF, DEFAULT_BRANCH, ACTOR, TRIGGERING_ACTOR (from the github context).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd jq

for v in REPO REF DEFAULT_BRANCH ACTOR TRIGGERING_ACTOR; do
  [ -n "${!v:-}" ] || die "$v is not set"
done

expected_repo="$(cfg .executionRepo)"
[ "$REPO" = "$expected_repo" ] || die "this workflow executes only in $expected_repo; this is $REPO"
[ "$REF" = "refs/heads/$DEFAULT_BRANCH" ] ||
  die "this workflow executes only from the default branch '$DEFAULT_BRANCH'; this run is on '$REF'"

# GitHub logins are case-insensitive.
for who in "$ACTOR" "$TRIGGERING_ACTOR"; do
  jq -e --arg u "$(lower "$who")" 'any(.dispatchers[]; ascii_downcase == $u)' "$CONFIG_FILE" >/dev/null ||
    die "'$who' may not start this workflow (dispatchers: $(jq -r '.dispatchers | join(", ")' "$CONFIG_FILE"))"
done
log "run by $TRIGGERING_ACTOR on $REF of $REPO"
