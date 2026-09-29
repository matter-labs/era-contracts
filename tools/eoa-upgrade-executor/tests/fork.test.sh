#!/usr/bin/env bash
# Sepolia fork simulation of the real v0.33.0 compiler stage file
# (l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/emergency-upgrade-board.json
# at 8ad567ab6, committed here as a fixture):
#
#   - all 13 transactions (12 approveHash + executeEmergencyUpgrade) pass
#   - the same file with one calldata byte flipped in the EXECUTE tx fails
#
# The fork block is before the first approveHash landed. Public nodes prune
# old state within days, so this uses a keyless archive gateway; override
# with FORK_RPC_URL.

# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"
scripts="$EXECUTOR_ROOT/scripts"
fixture="$EXECUTOR_ROOT/tests/fixtures/v0.33.0-compiler-stage-emergency-upgrade-board.json"
FIXTURE_COMMIT=8ad567ab6eb1f142338dd0eda2d70d2d394687ef
FIXTURE_PATH=l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/emergency-upgrade-board.json
FIXTURE_BLOB=881b72ed9f3722682b3ddc6ac153e5b3ca464b16
# The stage owner EOA's nonce is 843 here: none of the 13 transactions has run yet.
FIXTURE_FORK_BLOCK=11808002
EXECUTE_INDEX=12
export FORK_RPC_URL="${FORK_RPC_URL:-https://sepolia.gateway.tenderly.co}"
export EXECUTOR_TEST=1

check_foundry
[ "$(git hash-object "$fixture")" = "$FIXTURE_BLOB" ] || die "fixture is not the upstream file (git blob mismatch)"
work="$(mktemp -d "${TMPDIR:-/tmp}/eoa-executor-fork-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failed=0

plan() {
  local dir="$1" file="$2"
  shift 2
  mkdir -p "$dir"
  cp "$file" "$dir/transactions.json"
  jq -n --arg c "$FIXTURE_COMMIT" --arg p "$FIXTURE_PATH" --arg b "$FIXTURE_BLOB" --arg s "$(sha256_of "$file")" \
    '{repo: "matter-labs/era-contracts", commit: $c, path: $p, gitBlobSha: $b, sha256: $s}' >"$dir/source.json"
  "$scripts/resolve.sh" --plan-dir "$dir" --environment stage --rpc-url "$FORK_RPC_URL" "$@"
}

echo "== all 13 transactions pass"
plan "$work/a" "$fixture"
if "$scripts/simulate.sh" --plan-dir "$work/a" --fork-block "$FIXTURE_FORK_BLOCK" &&
  [ "$(jq -s 'map(select(.status == "success")) | length' "$work/a/simulation/results.jsonl")" = 13 ]; then
  echo "ok     13 txs simulate"
else
  echo "FAILED all 13 txs should simulate"
  failed=1
fi

echo "== one calldata byte flipped in the EXECUTE tx fails"
jq --argjson i "$EXECUTE_INDEX" \
  '.transactions[$i].data |= (.[0:20000] + (if .[20000:20001] == "f" then "e" else "f" end) + .[20001:])' \
  "$fixture" >"$work/tampered.json"
plan "$work/c" "$work/tampered.json"
if "$scripts/simulate.sh" --plan-dir "$work/c" --fork-block "$FIXTURE_FORK_BLOCK" 2>"$work/c.log"; then
  echo "FAILED tampered file should not simulate"
  failed=1
elif grep -q "tx $EXECUTE_INDEX: eth_call reverts" "$work/c.log" && grep -q "Invalid guardians signatures" "$work/c.log" &&
  [ "$(jq -s length "$work/c/simulation/results.jsonl")" = "$EXECUTE_INDEX" ]; then
  echo "ok     tampered EXECUTE reverts (Invalid guardians signatures) after the 12 approvals succeed"
else
  echo "FAILED tampered file failed for another reason:"
  tail -n 20 "$work/c.log"
  failed=1
fi

[ "$failed" -eq 0 ]
