#!/usr/bin/env bash
# Offline tests for the executor. Nothing here touches a real network.
#
#   1. fetch.sh: input validation, and reading a file at a commit of a scratch git repo
#   2. resolve.sh: both file formats, ranges, senders, value policy, chain id
#   3. check-run.sh: repository, branch and dispatcher checks
#   4. check-environment.sh against a fake `gh` (isolates the test from the
#      GitHub API; only the policy logic is under test)
#   5. simulate.sh against a fork of the local anvil
#   6. execute.sh key mode against a plain local anvil (not a fork) with
#      throwaway keystores: key checks, dry run, the send-and-wait loop, stop on
#      a failing pre-send check, the pending-tx guard, fee caps, a second RPC
#      that disagrees (other chain, unreachable, other state, withheld
#      receipt), and that neither the keystore nor its password reaches a
#      command line, a child's environment or the output
#   7. the broadcast job of the workflow runs no action and reads the secrets
#      only in its last step
#
# Only the anvil processes started here are stopped at exit.

# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"
scripts="$EXECUTOR_ROOT/scripts"
check_foundry
require_cmd "$ANVIL" git
export EXECUTOR_TEST=1

work="$(mktemp -d "${TMPDIR:-/tmp}/eoa-executor-test.XXXXXX")"
passed=0
failed=0

pass() { passed=$((passed + 1)); printf 'ok     %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAILED %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -n 25; }

# expect_ok NAME CMD...            the command must succeed
# expect_fail NAME PATTERN CMD...  the command must fail with PATTERN in its output
expect_ok() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi
}
expect_fail() {
  local name="$1" pattern="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    fail "$name (unexpectedly succeeded)" "$out"
  elif grep -qF -- "$pattern" <<<"$out"; then
    pass "$name"
  else
    fail "$name (expected: $pattern)" "$out"
  fi
}
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
jq_true() { jq -s -e "$1" "$2" >/dev/null; }
line_after() { [ -n "$1" ] && [ "$1" -gt "$2" ]; }

# ---------------------------------------------------------------- local anvil
port="$(find_free_port "$FIRST_ANVIL_PORT")"
rpc="http://127.0.0.1:$port"
# Interval mining, so that publishing and mining are separate steps and the
# receipt wait actually waits.
"$ANVIL" --port "$port" --host 127.0.0.1 --chain-id 31337 --block-time 2 >"$work/anvil.log" 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid" ${anvil2_pid:+"$anvil2_pid"} ${anvil3_pid:+"$anvil3_pid"} 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$work"' EXIT
wait_for_rpc "$rpc" "$anvil_pid"
# Two more, as disagreeing second RPCs: same chain id but other state, and another chain.
port2="$(find_free_port $((port + 1)))"
rpc_other_state="http://127.0.0.1:$port2"
"$ANVIL" --port "$port2" --host 127.0.0.1 --chain-id 31337 >"$work/anvil2.log" 2>&1 &
anvil2_pid=$!
wait_for_rpc "$rpc_other_state" "$anvil2_pid"
port3="$(find_free_port $((port2 + 1)))"
rpc_other_chain="http://127.0.0.1:$port3"
"$ANVIL" --port "$port3" --host 127.0.0.1 --chain-id 1 >"$work/anvil3.log" 2>&1 &
anvil3_pid=$!
wait_for_rpc "$rpc_other_chain" "$anvil3_pid"
rpc_unreachable="http://127.0.0.1:$(find_free_port $((port3 + 1)))"

# Anvil's dev account 9 (key from its startup banner) only funds the test accounts.
K9="$(sed -n 's/^(9) \(0x[0-9a-f]\{64\}\)$/\1/p' "$work/anvil.log")"
[ -n "$K9" ] || die "could not read dev key 9 from the anvil banner"

# Throwaway keystores, created the way devops would create the real one.
new_keystore() { mkdir -p "$1" && CAST_PASSWORD="$2" "$CAST" wallet new "$1" --json | jq -r '.[0].address'; }
EXEC_PW="exec-$RANDOM$RANDOM"
OTHER_PW="other-$RANDOM$RANDOM"
EXEC="$(new_keystore "$work/ks-exec" "$EXEC_PW")"
OTHER="$(new_keystore "$work/ks-other" "$OTHER_PW")"
EXEC_KS="$(cat "$work/ks-exec"/*)"
OTHER_KS="$(cat "$work/ks-other"/*)"
EXEC_CIPHERTEXT="$(jq -r .crypto.ciphertext <<<"$EXEC_KS")"
R5="0x00000000000000000000000000000000000000a5"
R6="0x00000000000000000000000000000000000000a6"

"$CAST" send --private-key "$K9" --rpc-url "$rpc" --value 50ether "$EXEC" >/dev/null
# A contract whose every call reverts (runtime: PUSH1 0 PUSH1 0 REVERT).
REVERTER="$("$CAST" send --private-key "$K9" --rpc-url "$rpc" --json \
  --create 0x6005600c60003960056000f360006000fd | jq -r .contractAddress)"
is_address "$REVERTER" || die "reverter deployment failed"

# Test config: the real one (fee caps included), with its networks pointed at
# this anvil, the same anvil under a second URL as the "independent" RPC, value
# transfers allowed (so balances can prove what was sent) and short waits.
jq --arg rpc "$rpc" '
  .environments = {local: {network: "anvil-local", githubEnvironment: "eoa-upgrade-local"}}
  | .networks = {"anvil-local": (.networks.sepolia + {chainId: 31337, rpcUrl: $rpc, secondaryRpcUrl: "\($rpc)/", explorerTxUrl: ""})}
  | .execution.allowNonZeroValue = true
  | .execution.receiptPollSeconds = 1
  | .execution.receiptTimeoutSeconds = 8
  | .execution.rpcAgreementRetries = 2' "$EXECUTOR_ROOT/config.json" >"$work/config.json"
# variant_config NAME JQ-FILTER: a copy of the test config with one change, for with_config.
variant_config() { jq "$2" "$work/config.json" >"$work/config-$1.json"; printf '%s\n' "$work/config-$1.json"; }
jq '.networks["anvil-local"].chainId = 1' "$work/config.json" >"$work/config-wrong-chain.json"
jq '.execution.allowNonZeroValue = false' "$work/config.json" >"$work/config-zero-value.json"
export EXECUTOR_CONFIG="$work/config.json"

# The two formats. transaction-simulator: value in ETH, several senders allowed.
jq -n --arg e "$EXEC" --arg o "$OTHER" --arg r5 "$R5" --arg r6 "$R6" --arg rv "$REVERTER" '[
  {description: "value transfer", network: "anvil-local", from: $e, to: $r5, value: "0.5", data: "0x"},
  {description: "calldata to an EOA", network: "anvil-local", from: $e, to: $r6, value: "0", data: "0xdeadbeef"},
  {description: "value and calldata", network: "anvil-local", from: $e, to: $r5, value: "0.25", data: "0x01", valueToMint: null},
  {description: "reverts", network: "anvil-local", from: $e, to: $rv, value: "0", data: "0x"},
  {description: "after the revert", network: "anvil-local", from: $e, to: $r6, value: "0", data: "0x"},
  {description: "another sender", network: "anvil-local", from: $o, to: $r5, value: "0.1", data: "0x"}
]' >"$work/txs.json"
# emergency-upgrade-board: value always 0, network from the environment.
jq -n --arg e "$EXEC" --arg r6 "$R6" '{
  _comment: "test board", emergency_upgrade_board: $r6, protocol_upgrade_handler: $r6, owner: $e,
  transactions: [
    {step: 1, label: "APPROVE 1", from: $e, to: $r6, data: "0xd4d9bdcd0000000000000000000000000000000000000000000000000000000000000001"},
    {step: 2, label: "EXECUTE", from: $e, to: $r6, data: "0xc03fd44b"}
  ]}' >"$work/board.json"

# make_plan DIR JSON-FILE [resolve args...]: a plan dir as fetch.sh would leave it, then resolve.
make_plan() {
  local dir="$1" file="$2"
  shift 2
  rm -rf "$dir" && mkdir -p "$dir"
  cp "$file" "$dir/transactions.json"
  jq -n '{repo: "local/fixture", commit: "0000000000000000000000000000000000000000",
          path: "test.json", gitBlobSha: "-", sha256: "-"}' >"$dir/source.json"
  "$scripts/resolve.sh" --plan-dir "$dir" --environment local --rpc-url "$rpc" "$@"
}
# variant NAME FILE JQ-FILTER: a copy of FILE with one change.
variant() { jq "$3" "$2" >"$work/$1.json"; printf '%s\n' "$work/$1.json"; }
nonce() { "$CAST" nonce "$1" --rpc-url "$rpc"; }
# with_config FILE CMD...: run CMD (a function too) with another config.
with_config() {
  local c="$1"
  shift
  EXECUTOR_CONFIG="$c" "$@"
}

echo "== fetch.sh"
good_sha=a92ad0057f77adfe6a6bdb46d8b2fb60b2ef804c
expect_ok "valid inputs pass --check-only" "$scripts/fetch.sh" --check-only "$good_sha" l1-contracts/upgrade-envs/v0.33.0-compiler/output/stage/emergency-upgrade-board.json
expect_fail "rejects a branch name" "full 40-hex" "$scripts/fetch.sh" --check-only draft-v31 a.json
expect_fail "rejects a short sha" "full 40-hex" "$scripts/fetch.sh" --check-only a92ad00 a.json
expect_fail "rejects an uppercase sha" "full 40-hex" "$scripts/fetch.sh" --check-only "$(printf '%s' "$good_sha" | tr a-f A-F)" a.json
expect_fail "rejects '..'" "repo-relative path" "$scripts/fetch.sh" --check-only "$good_sha" l1-contracts/../x.json
expect_fail "rejects an absolute path" "repo-relative path" "$scripts/fetch.sh" --check-only "$good_sha" /etc/x.json
expect_fail "rejects glob characters" "repo-relative path" "$scripts/fetch.sh" --check-only "$good_sha" 'l1-contracts/*.json'
expect_fail "rejects a leading dash" "repo-relative path" "$scripts/fetch.sh" --check-only "$good_sha" -x.json
expect_fail "rejects non-json files" "repo-relative path" "$scripts/fetch.sh" --check-only "$good_sha" README.md
git init -q "$work/repo"
mkdir -p "$work/repo/out/stage"
cp "$work/board.json" "$work/repo/out/stage/board.json"
mkdir -p "$work/repo/out/dir.json"
echo '{}' >"$work/repo/out/dir.json/x.json"
git -C "$work/repo" add out
git -C "$work/repo" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m fixture
repo_sha="$(git -C "$work/repo" rev-parse HEAD)"
expect_ok "reads a file at a commit" "$scripts/fetch.sh" "$repo_sha" out/stage/board.json "$work/repo" "$work/f"
check "the file is byte for byte the committed one" cmp -s "$work/board.json" "$work/f/transactions.json"
check "source.json names commit, path and blob" \
  [ "$(jq -c '[.commit, .path, .gitBlobSha]' "$work/f/source.json")" = "[\"$repo_sha\",\"out/stage/board.json\",\"$(git -C "$work/repo" rev-parse "$repo_sha:out/stage/board.json")\"]" ]
expect_fail "missing path" "is not a file at commit" "$scripts/fetch.sh" "$repo_sha" out/stage/nope.json "$work/repo" "$work/f"
expect_fail "a directory named like a file" "is not a file at commit" "$scripts/fetch.sh" "$repo_sha" out/dir.json "$work/repo" "$work/f"
expect_fail "unknown commit" "is not in" "$scripts/fetch.sh" ffffffffffffffffffffffffffffffffffffffff out/stage/board.json "$work/repo" "$work/f"

echo "== resolve.sh: transaction-simulator format"
expect_ok "valid file, range 0-2" make_plan "$work/p" "$work/txs.json" --range 0-2
check "plan holds 3 txs from the one sender" \
  [ "$(jq -c '[.format, (.transactions | length), .sender, .transactions[0].valueWei, .transactions[1].selector]' "$work/p/plan.json")" = "[\"transaction-simulator\",3,\"$EXEC\",\"500000000000000000\",\"0xdeadbeef\"]" ]
check "summary lists the txs outside the range" grep -q 'Not in this run' "$work/p/summary.md"
check "plan sha256 file matches" [ "$(cat "$work/p/plan.json.sha256")" = "$(sha256_of "$work/p/plan.json")" ]
expect_fail "unknown field" "unknown field(s): gasLimit" make_plan "$work/p" "$(variant f1 "$work/txs.json" '.[0].gasLimit = "1"')"
expect_fail "missing field" "data must be a string" make_plan "$work/p" "$(variant f2 "$work/txs.json" 'del(.[1].data)')"
expect_fail "bad address" "not a 20-byte hex address" make_plan "$work/p" "$(variant f3 "$work/txs.json" '.[2].to = "0x1234"')"
# Upper-case the first lower-case hex letter: still mixed case, checksum now wrong.
bad_checksum="$(printf '%s\n' "$EXEC" | awk '{ for (i = 3; i <= length($0); i++) { c = substr($0, i, 1)
  if (c ~ /[a-f]/) { print substr($0, 1, i - 1) toupper(c) substr($0, i + 1); exit } } }')"
expect_fail "bad EIP-55 checksum" "invalid EIP-55 checksum" make_plan "$work/p" "$(variant f4 "$work/txs.json" ".[4].from = \"$bad_checksum\"")"
expect_fail "odd-length calldata" "even-length hex" make_plan "$work/p" "$(variant f5 "$work/txs.json" '.[1].data = "0xabc"')"
expect_fail "value not in decimal ETH" "decimal ETH amount" make_plan "$work/p" "$(variant f6 "$work/txs.json" '.[0].value = "1e18"')"
expect_fail "value with 19 decimals" "decimal ETH amount" make_plan "$work/p" "$(variant f7 "$work/txs.json" '.[0].value = "0.0000000000000000001"')"
expect_fail "control characters in a description" "control characters" make_plan "$work/p" "$(variant f8 "$work/txs.json" '.[0].description = "a\nb"')"
expect_fail "empty file" "no transactions" make_plan "$work/p" "$(variant f9 "$work/txs.json" '[]')"
expect_fail "network mismatch" "environment expects" make_plan "$work/p" "$(variant f10 "$work/txs.json" '.[1].network = "sepolia"')" --range 0-2
expect_ok "network mismatch outside the range is fine" make_plan "$work/p" "$(variant f11 "$work/txs.json" '.[5].network = "sepolia"')" --range 0-2
expect_fail "testOnly in range" "testOnly" make_plan "$work/p" "$(variant f12 "$work/txs.json" '.[1].testOnly = true')" --range 0-2
expect_ok "testOnly outside the range" make_plan "$work/p" "$(variant f13 "$work/txs.json" '.[4].testOnly = true')" --range 0-2
expect_fail "timeIncrease in range" "timeIncrease" make_plan "$work/p" "$(variant f14 "$work/txs.json" '.[0].timeIncrease = "86400"')" --range 0
expect_fail "emulateAllBatchesExecuted in range" "emulateAllBatchesExecuted" make_plan "$work/p" "$(variant f15 "$work/txs.json" '.[0].emulateAllBatchesExecuted = true')" --range 0
expect_fail "value refused by the default config" "only zero-value" \
  with_config "$work/config-zero-value.json" make_plan "$work/p" "$work/txs.json" --range 0-2
expect_ok "zero-value txs pass the default config" \
  with_config "$work/config-zero-value.json" make_plan "$work/p" "$work/txs.json" --range 1
expect_fail "range syntax" "range must be" make_plan "$work/p" "$work/txs.json" --range 1..2
expect_fail "range reversed" "is after its end" make_plan "$work/p" "$work/txs.json" --range 3-1
expect_fail "range out of bounds" "out of bounds" make_plan "$work/p" "$work/txs.json" --range 0-6
expect_fail "two senders in one run" "different senders" make_plan "$work/p" "$work/txs.json"
expect_ok "two senders with --simulation-only" make_plan "$work/p-sim" "$work/txs.json" --simulation-only
check "simulation-only plan has no sender" [ "$(jq -c '[.simulationOnly, .sender]' "$work/p-sim/plan.json")" = "[true,null]" ]
expect_fail "unknown environment" "unknown environment" \
  "$scripts/resolve.sh" --plan-dir "$work/p" --environment mainnet --rpc-url "$rpc"
expect_fail "RPC chain id mismatch" "chain id mismatch" \
  env EXECUTOR_CONFIG="$work/config-wrong-chain.json" "$scripts/resolve.sh" --plan-dir "$work/p" --environment local --range 0-2 --rpc-url "$rpc"
expect_fail "neither format" "neither" make_plan "$work/p" "$(variant f16 "$work/txs.json" '{a: 1}')"

echo "== resolve.sh: emergency-upgrade-board format"
expect_ok "valid board" make_plan "$work/b" "$work/board.json"
check "board txs get the environment's network, value 0 and step labels" \
  [ "$(jq -c '[.format, .sender, (.transactions | map(.description)), (.transactions | map(.valueWei) | unique)]' "$work/b/plan.json")" = "[\"emergency-upgrade-board\",\"$EXEC\",[\"step 1: APPROVE 1\",\"step 2: EXECUTE\"],[\"0\"]]" ]
check "summary shows the owner" grep -q "| owner | \`$EXEC\` |" "$work/b/summary.md"
expect_fail "unknown top-level field" "unknown top-level field(s): chain" make_plan "$work/b" "$(variant g1 "$work/board.json" '.chain = 1')"
expect_fail "unknown tx field (no value in this format)" "unknown field(s): value" make_plan "$work/b" "$(variant g2 "$work/board.json" '.transactions[0].value = "1"')"
expect_fail "steps out of order" "steps must run" make_plan "$work/b" "$(variant g3 "$work/board.json" '.transactions |= reverse')"
expect_fail "owner is not an address" "owner is not a 20-byte hex address" make_plan "$work/b" "$(variant g4 "$work/board.json" '.owner = "me"')"
expect_fail "empty board" "no transactions" make_plan "$work/b" "$(variant g5 "$work/board.json" '.transactions = []')"
expect_fail "board tx with a bad address" "not a 20-byte hex address" make_plan "$work/b" "$(variant g6 "$work/board.json" '.transactions[1].to = "0x12"')"

echo "== check-on-branch.sh (fake curl)"
# A stand-in for curl that answers the compare API with $FAKE_COMPARE (or fails
# when it is "404"), so the upstream-branch rule is tested without GitHub.
mkdir -p "$work/fakebin"
cat >"$work/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
[ "$FAKE_COMPARE" != 404 ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
printf '{"status":"%s"}\n' "$FAKE_COMPARE"
EOF
chmod +x "$work/fakebin/curl"
upstream=matter-labs/era-contracts
on_branch() { env PATH="$work/fakebin:$PATH" FAKE_CURL_LOG="$work/curl.log" FAKE_COMPARE="$1" "$scripts/check-on-branch.sh" "${@:2}"; }
expect_ok "commit equal to the branch tip" on_branch identical "$upstream" draft-v31 "$good_sha"
expect_ok "commit behind the branch tip" on_branch behind "$upstream" kl/v33-stage "$good_sha"
check "it asks compare/<branch>...<sha>" grep -q "repos/$upstream/compare/kl/v33-stage...$good_sha" "$work/curl.log"
expect_fail "commit ahead of the branch (not merged into it)" "is not on $upstream branch draft-v31" on_branch ahead "$upstream" draft-v31 "$good_sha"
expect_fail "diverged commit (e.g. only in a fork)" "compare says 'diverged'" on_branch diverged "$upstream" draft-v31 "$good_sha"
expect_fail "unknown commit or branch" "cannot compare" on_branch 404 "$upstream" draft-v31 "$good_sha"
expect_fail "branch with '..'" "plain branch name" on_branch identical "$upstream" 'a..b' "$good_sha"
expect_fail "branch with a leading dash" "plain branch name" on_branch identical "$upstream" -x "$good_sha"
expect_fail "short sha" "full 40-hex" on_branch identical "$upstream" draft-v31 a92ad00
expect_fail "bad repository" "owner/name" on_branch identical 'evil/../x' draft-v31 "$good_sha"
expect_fail "git-fetch.sh stops at the branch check, before any fetch" "is not on $upstream branch" \
  env PATH="$work/fakebin:$PATH" FAKE_CURL_LOG="$work/curl.log" FAKE_COMPARE=diverged \
  "$scripts/git-fetch.sh" "$upstream" draft-v31 "$good_sha" a.json "$work/gf"
check "git-fetch.sh created nothing" [ ! -e "$work/gf" ]

echo "== check-run.sh"
run_case() {
  local name="$1" pattern="$2" repo="$3" ref="$4" actor="$5" trig="${6:-$5}"
  local cmd=(env REPO="$repo" REF="$ref" DEFAULT_BRANCH=executor ACTOR="$actor" TRIGGERING_ACTOR="$trig" "$scripts/check-run.sh")
  if [ -z "$pattern" ]; then expect_ok "$name" "${cmd[@]}"; else expect_fail "$name" "$pattern" "${cmd[@]}"; fi
}
private=matter-labs/era-contracts-private
run_case "dispatcher on the default branch" "" "$private" refs/heads/executor kelemeno
run_case "logins are case-insensitive" "" "$private" refs/heads/executor stanislavbreadless
run_case "public repository" "executes only in" matter-labs/era-contracts refs/heads/executor kelemeno
run_case "another branch" "only from the default branch" "$private" refs/heads/kl/x kelemeno
run_case "someone else dispatches" "may not start" "$private" refs/heads/executor octocat
run_case "a bot account with a similar name" "may not start" "$private" refs/heads/executor StanislavBreadfulAI
run_case "re-run by someone else" "may not start" "$private" refs/heads/executor kelemeno octocat

echo "== check-environment.sh (fake gh)"
mkdir -p "$work/fakebin" "$work/gh"
cat >"$work/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# Stand-in for `gh api`: serves $FAKE_GH_DIR/{env,policies,branches}.json.
[ "$1" = api ] || exit 2
shift
path="" filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in --jq) filter="$2"; shift 2 ;; -H) shift 2 ;; --paginate) shift ;; *) path="$1"; shift ;; esac
done
case "$path" in
  */deployment-branch-policies) f="$FAKE_GH_DIR/policies.json" ;;
  */environments/*) f="$FAKE_GH_DIR/env.json" ;;
  */branches\?protected=true*) f="$FAKE_GH_DIR/branches.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$filter" ]; then jq -r "$filter" "$f"; else cat "$f"; fi
EOF
chmod +x "$work/fakebin/gh"
# What terraform-configurations creates: the approver team, self-review
# prevented, no admin bypass, "protected branches" policy.
good_env='{"name":"eoa-upgrade-local","can_admins_bypass":false,
  "protection_rules":[{"type":"required_reviewers","prevent_self_review":true,"reviewers":[
    {"type":"Team","reviewer":{"slug":"protocol-upgrade-approvers","name":"protocol-upgrade-approvers"}}]},
    {"type":"branch_policy"}],
  "deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}'
custom_policy='.deployment_branch_policy = {protected_branches: false, custom_branch_policies: true}'
good_policies='{"total_count":1,"branch_policies":[{"name":"executor","type":"branch"}]}'
good_branches='[{"name":"executor","protected":true}]'
# env_case NAME PATTERN|"" ENV-JQ POLICIES-JQ BRANCHES-JQ [GITHUB-ENVIRONMENT-NAME]
env_case() {
  local name="$1" pattern="$2" env_filter="$3" pol_filter="$4" br_filter="$5" gh_env="${6:-eoa-upgrade-local}"
  rm -f "$work/gh/"*.json
  if [ "$env_filter" != absent ]; then jq "$env_filter" <<<"$good_env" >"$work/gh/env.json"; fi
  jq "$pol_filter" <<<"$good_policies" >"$work/gh/policies.json"
  jq "$br_filter" <<<"$good_branches" >"$work/gh/branches.json"
  local cmd=(env -u GITHUB_STEP_SUMMARY PATH="$work/fakebin:$PATH" FAKE_GH_DIR="$work/gh" REPO="$private"
    ENVIRONMENT=local GITHUB_ENVIRONMENT_NAME="$gh_env" DEFAULT_BRANCH=executor "$scripts/check-environment.sh")
  if [ -z "$pattern" ]; then expect_ok "$name" "${cmd[@]}"; else expect_fail "$name" "$pattern" "${cmd[@]}"; fi
}
env_case "team + protected branches passes" "" . . .
env_out="$(env -u GITHUB_STEP_SUMMARY PATH="$work/fakebin:$PATH" FAKE_GH_DIR="$work/gh" REPO="$private" ENVIRONMENT=local \
  GITHUB_ENVIRONMENT_NAME=eoa-upgrade-local DEFAULT_BRANCH=executor "$scripts/check-environment.sh" 2>&1)"
check "the report names the team and the policy" grep -q 'team `protocol-upgrade-approvers`.*protected branches' <<<"$env_out"
env_case "team + custom list of only the default branch passes" "" "$custom_policy" . .
env_case "other protected branches are reported, not refused" "" . . '. + [{name: "main", protected: true}]'
env_out="$(env -u GITHUB_STEP_SUMMARY PATH="$work/fakebin:$PATH" FAKE_GH_DIR="$work/gh" REPO="$private" ENVIRONMENT=local \
  GITHUB_ENVIRONMENT_NAME=eoa-upgrade-local DEFAULT_BRANCH=executor "$scripts/check-environment.sh" 2>&1)"
check "the report lists them" grep -q 'can also deploy.*: main' <<<"$env_out"
env_case "protected branches, default branch unprotected" "is not protected" . . '[{name: "main", protected: true}]'
env_case "workflow and config disagree on the name" "config.json says" . . . eoa-upgrade-other
env_case "environment missing" "does not exist" absent . .
env_case "no required reviewers" "no required reviewers" '.protection_rules |= map(select(.type != "required_reviewers"))' . .
env_case "a user instead of the team" "expected only [team:protocol-upgrade-approvers]" \
  '.protection_rules[0].reviewers = [{type: "User", reviewer: {login: "kelemeno"}}]' . .
env_case "the team plus a user" "expected only" '.protection_rules[0].reviewers += [{type: "User", reviewer: {login: "octocat"}}]' . .
env_case "another team" "team:era-reviewers" '.protection_rules[0].reviewers = [{type: "Team", reviewer: {slug: "era-reviewers"}}]' . .
env_case "empty reviewer list" "expected only" '.protection_rules[0].reviewers = []' . .
env_case "self-review allowed" "Prevent self-review" '.protection_rules[0].prevent_self_review = false' . .
env_case "admin bypass allowed" "administrators can bypass" '.can_admins_bypass = true' . .
env_case "no branch policy" "any branch" '.deployment_branch_policy = null' . .
env_case "protected_branches false and no custom list" "must be \"protected branches\" or a custom list" \
  '.deployment_branch_policy = {protected_branches: false, custom_branch_policies: false}' . .
env_case "both policy kinds at once" "must be \"protected branches\" or a custom list" \
  '.deployment_branch_policy = {protected_branches: true, custom_branch_policies: true}' . .
env_case "custom list with an extra branch" "must be exactly" "$custom_policy" '.branch_policies += [{name: "main", type: "branch"}]' .
env_case "custom list with a wildcard" "must be exactly" "$custom_policy" '.branch_policies = [{name: "*", type: "branch"}]' .

echo "== simulate.sh (fork of the local anvil)"
make_plan "$work/p" "$work/txs.json" --range 0-2 >/dev/null 2>&1
expect_ok "simulation of 0-2 passes" env FORK_RPC_URL="$rpc" "$scripts/simulate.sh" --plan-dir "$work/p"
make_plan "$work/p-bad" "$work/txs.json" --range 1-4 >/dev/null 2>&1
expect_fail "simulation of 1-4 stops at the reverting tx 3" "tx 3: eth_call reverts" \
  env FORK_RPC_URL="$rpc" "$scripts/simulate.sh" --plan-dir "$work/p-bad"
check "failure details and a trace are kept" grep -q 'Traces:' "$work/p-bad/simulation/tx-3.failure.txt"
check "the simulation did not touch the local chain" [ "$(nonce "$EXEC")" = 0 ]

echo "== execute.sh key mode (local anvil, throwaway keystores)"
# A cast shim that records every command line and whether the secrets are in
# its environment, then runs the real cast.
real_cast="$(command -v "$CAST")"
cat >"$work/fakebin/cast" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/cast-argv.log"
env | grep -c '^EXECUTOR_KEYSTORE' >>"$work/cast-env.log" || true
# FAKE_ZERO_FEE_RECEIPTS: receipts claim the tx cost nothing, as a lying RPC could.
if [ "\$1" = receipt ] && [ -n "\${FAKE_ZERO_FEE_RECEIPTS:-}" ]; then
  r="\$("$real_cast" "\$@")" || exit \$?
  jq -c '.effectiveGasPrice = "0x0" | .gasUsed = "0x0"' <<<"\$r"
  exit 0
fi
exec "$real_cast" "\$@"
EOF
chmod +x "$work/fakebin/cast"
mkdir -p "$work/tmp"
# exec_key KEYSTORE PASSWORD PLAN-DIR [execute args...]
exec_key() {
  local ks="$1" pw="$2" dir="$3"
  shift 3
  env CAST="$work/fakebin/cast" RUNNER_TEMP="$work/tmp" EXECUTOR_KEYSTORE="$ks" EXECUTOR_KEYSTORE_PASSWORD="$pw" \
    "$scripts/execute.sh" --plan "$dir/plan.json" --mode key --out "$dir/broadcast" "$@" 2>&1 |
    tee -a "$work/exec-output.log"
  return "${PIPESTATUS[0]}"
}
make_plan "$work/p" "$work/txs.json" --range 0-2 >/dev/null 2>&1
expect_fail "keystore of another account" "is for $OTHER but the plan's sender is $EXEC" exec_key "$OTHER_KS" "$OTHER_PW" "$work/p"
expect_fail "wrong password" "cannot decrypt EXECUTOR_KEYSTORE" exec_key "$EXEC_KS" "wrong" "$work/p"
expect_fail "keystore without password" "EXECUTOR_KEYSTORE_PASSWORD is not set" exec_key "$EXEC_KS" "" "$work/p"
expect_fail "no keystore, live run" "EXECUTOR_KEYSTORE is not set" exec_key "" "" "$work/p"
expect_ok "no keystore, dry run" exec_key "" "" "$work/p" --dry-run
check "dry run without keystore reports it stopped" grep -q 'DRY RUN' "$work/p/broadcast/results.md"
expect_ok "right keystore, dry run" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p" --dry-run
expect_fail "simulation-only plan is never signed" "simulation-only" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p-sim"
check "nothing was sent by the refused and dry runs" [ "$(nonce "$EXEC")" = 0 ]

expect_ok "live run of 0-2 sends and waits for each receipt" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
check "3 receipts, all EIP-1559 and successful" \
  [ "$(jq -s -c '[length, (map(.type) | unique), (map(.status) | unique)]' "$work/p/broadcast"/tx-*.receipt.json)" = '[3,["0x2"],["0x1"]]' ]
check "one tx per block, in order (sent only after the previous receipt)" \
  jq_true 'map(.blockNumber) | length == 3 and .[0] < .[1] and .[1] < .[2]' "$work/p/broadcast/results.jsonl"
check "sender nonce advanced by 3" [ "$(nonce "$EXEC")" = 3 ]
check "recipient got 0.75 ETH" [ "$("$CAST" balance "$R5" --rpc-url "$rpc")" = 750000000000000000 ]

make_plan "$work/p-bad" "$work/txs.json" --range 1-4 >/dev/null 2>&1
expect_fail "live run of 1-4 stops at the pre-send check of tx 3" "tx 3: eth_call reverts" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p-bad"
check "only txs 1 and 2 were sent; tx 4 was not" [ "$(nonce "$EXEC"):$(jq -s -c 'map(.index)' "$work/p-bad/broadcast/results.jsonl")" = "5:[1,2]" ]

# A transaction stuck in the mempool must block a run: pause mining, leave one pending.
printf '%s' "$EXEC_PW" >"$work/exec-pw"
"$CAST" rpc evm_setIntervalMining 0 --rpc-url "$rpc" >/dev/null
ETH_KEYSTORE="$(ls "$work/ks-exec"/*)" ETH_PASSWORD="$work/exec-pw" "$CAST" send --async --rpc-url "$rpc" "$R6" >/dev/null
expect_fail "pending tx from the sender blocks the run" "pending transaction(s)" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
"$CAST" rpc evm_setIntervalMining 2 --rpc-url "$rpc" >/dev/null

echo "== fee caps (checked before signing)"
# Let the tx left pending above be mined first.
for _ in $(seq 1 20); do
  [ "$(nonce "$EXEC")" = "$("$CAST" nonce "$EXEC" --block pending --rpc-url "$rpc")" ] && break
  sleep 1
done
make_plan "$work/p" "$work/txs.json" --range 1-2 >/dev/null 2>&1
before="$(nonce "$EXEC")"
net='.networks["anvil-local"]'
expect_fail "priority fee over the cap" "exceeds the cap 1 for anvil-local" \
  with_config "$(variant_config prio "$net.maxPriorityFeePerGasWei = \"1\"")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
expect_fail "max fee per gas over the cap" "exceeds the max fee cap 1000" \
  with_config "$(variant_config maxfee "$net.maxFeePerGasWei = \"1000\"")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
expect_fail "fee budget of the run exceeded" "exceeds this run's fee budget 1 " \
  with_config "$(variant_config budget "$net.maxRunFeeWei = \"1\"")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
expect_fail "a cap that could overflow is refused" "must stay below 2^62" \
  with_config "$(variant_config overflow "$net.maxFeePerGasWei = \"999999999999999999\"")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
check "nothing was signed or sent over a cap" [ "$(nonce "$EXEC")" = "$before" ]
check "the summary of a refused run says why" grep -q "fee budget" "$work/p/broadcast/results.md"
# The budget reserves each tx's worst case before signing and never credits a
# receipt: with receipts claiming zero fees, a budget of 1.5 worst cases still
# stops the second tx.
jq -n --arg e "$EXEC" --arg r6 "$R6" '[
  {description: "b1", network: "anvil-local", from: $e, to: $r6, value: "0", data: "0x01"},
  {description: "b2", network: "anvil-local", from: $e, to: $r6, value: "0", data: "0x02"}]' >"$work/b2.json"
make_plan "$work/pb" "$work/b2.json" >/dev/null 2>&1
worst0="$(exec_key "$EXEC_KS" "$EXEC_PW" "$work/pb" --dry-run | sed -n 's/.*worst-case fee \([0-9]*\)$/\1/p')"
before="$(nonce "$EXEC")"
check "the dry run reports the first tx's worst-case fee" [ -n "$worst0" ]
with_zero_fee_receipts() { FAKE_ZERO_FEE_RECEIPTS=1 "$@"; }
expect_fail "zero-fee receipts do not free the budget" "wei already reserved exceeds this run's fee budget" \
  with_zero_fee_receipts with_config "$(variant_config budget2 "$net.maxRunFeeWei = \"$((worst0 * 3 / 2))\"")" \
  exec_key "$EXEC_KS" "$EXEC_PW" "$work/pb"
check "the first receipt did claim a zero fee" [ "$(jq -r '[.effectiveGasPrice, .gasUsed] | join(" ")' "$work/pb/broadcast"/tx-*.receipt.json)" = "0x0 0x0" ]
check "only the first of the two txs was sent" \
  [ "$(($(nonce "$EXEC") - before)):$(wc -l <"$work/pb/broadcast/results.jsonl" | tr -d ' ')" = "1:1" ]

echo "== a second RPC that disagrees fails closed"
before="$(nonce "$EXEC")"
secondary() { variant_config "$1" "$net.secondaryRpcUrl = \"$2\""; }
expect_fail "second RPC on another chain" "do not agree on the chain id" \
  with_config "$(secondary chain "$rpc_other_chain")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
expect_fail "second RPC unreachable" "do not agree on the chain id (or one did not answer)" \
  with_config "$(secondary down "$rpc_unreachable")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
expect_fail "second RPC reports another nonce" "do not agree on the nonce of $EXEC" \
  with_config "$(secondary state "$rpc_other_state")" exec_key "$EXEC_KS" "$EXEC_PW" "$work/p"
check "nothing was sent while they disagreed" [ "$(nonce "$EXEC")" = "$before" ]
# A fresh account has nonce 0 on both chains, so every pre-send check agrees;
# it is funded only on the main anvil, so the second RPC never gets the tx.
# That is what a primary faking a receipt for a withheld tx looks like.
W_PW="w-$RANDOM$RANDOM"
W="$(new_keystore "$work/ks-w" "$W_PW")"
W_KS="$(cat "$work/ks-w"/*)"
"$CAST" send --private-key "$K9" --rpc-url "$rpc" --value 1ether "$W" >/dev/null
jq -n --arg w "$W" --arg r6 "$R6" '[
  {description: "one", network: "anvil-local", from: $w, to: $r6, value: "0", data: "0x01"},
  {description: "two", network: "anvil-local", from: $w, to: $r6, value: "0", data: "0x02"}]' >"$work/w.json"
make_plan "$work/pw" "$work/w.json" >/dev/null 2>&1
expect_fail "a receipt only one RPC can see stops the run" "from the secondary RPC after" \
  with_config "$(secondary state "$rpc_other_state")" exec_key "$W_KS" "$W_PW" "$work/pw"
check "it stopped after that tx: tx two was not sent, nothing reported as success" \
  [ "$(nonce "$W"):$(wc -l <"$work/pw/broadcast/results.jsonl" | tr -d ' ')" = "1:0" ]
check "the summary says why" grep -q 'no receipt' "$work/pw/broadcast/results.md"

echo "== the secrets stay secret"
check "cast ran with the keystore (mktx seen)" grep -q '^mktx ' "$work/cast-argv.log"
check "no command line holds the password or the keystore" \
  bash -c "! grep -qF -e '$EXEC_PW' -e '$EXEC_CIPHERTEXT' '$work/cast-argv.log'"
check "no cast process inherited EXECUTOR_KEYSTORE*" bash -c "! grep -qv '^0\$' '$work/cast-env.log'"
check "no output holds the password or the keystore" \
  bash -c "! grep -qF -e '$EXEC_PW' -e '$EXEC_CIPHERTEXT' '$work/exec-output.log'"
check "the key files were deleted" bash -c "[ -z \"\$(ls -A '$work/tmp')\" ]"

echo "== the workflow (static checks)"
wf="$EXECUTOR_ROOT/../../.github/workflows/execute-eoa-upgrade.yaml"
# job_lines NAME: the job's lines without comments, from "  NAME:" to the next job or EOF.
job_lines() { awk -v j="  $1:" '$0 == j {f = 1; next} f && /^  [A-Za-z0-9_-]+:/ {f = 0} f' "$wf" | grep -v '^[[:space:]]*#'; }
no_uses() { local lines; lines="$(job_lines "$1")"; [ -n "$lines" ] && ! grep -q 'uses:' <<<"$lines"; }
# resolve renders the approval table and the plan hash; preflight gates
# broadcast; broadcast holds the key. None of them may run an action.
for j in resolve preflight broadcast; do
  check "the $j job runs no action (no uses:)" no_uses "$j"
done
job="$(job_lines broadcast)"
last_step="$(grep -n '^      - name:' <<<"$job" | tail -n 1)"
first_secret="$(grep -n 'secrets\.' <<<"$job" | head -n 1 | cut -d: -f1)"
check "its last step is Send" [ "${last_step#*- name: }" = Send ]
check "secrets are read only in that last step" line_after "$first_secret" "${last_step%%:*}"
check "no other job reads a secret" [ "$(grep -c 'secrets\.' "$wf")" = "$(grep -c 'secrets\.' <<<"$job")" ]
check "it is a reusable workflow (workflow_call only)" \
  bash -c 'grep -q "^  workflow_call:" "$1" && ! grep -q "workflow_dispatch\|pull_request\|^  push:" "$1"' _ "$wf"
check "the only action anywhere is the pinned upload of the simulate traces" \
  [ "$(grep -v '^[[:space:]]*#' "$wf" | grep 'uses:' | sed 's/^ *- *//' | sort -u)" = "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1" ]
check "UPSTREAM_REPO matches config.json's upstreamRepo" \
  [ "$(sed -n 's/^  UPSTREAM_REPO: //p' "$wf")" = "$(jq -r .upstreamRepo "$EXECUTOR_ROOT/config.json")" ]
check "resolve checks that the workflow runs at executor_sha (the caller's referenced_workflows)" \
  bash -c 'job_lines() { awk -v j="  $1:" '"'"'$0 == j {f = 1; next} f && /^  [A-Za-z0-9_-]+:/ {f = 0} f'"'"' "$2"; }; job_lines resolve "$1" | grep -q referenced_workflows' _ "$wf"
check "every job fetches the executor with the upstream-branch check" \
  [ "$(grep -c 'compare/$EXECUTOR_BRANCH...$EXECUTOR_SHA' "$wf")" = 4 ]

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
