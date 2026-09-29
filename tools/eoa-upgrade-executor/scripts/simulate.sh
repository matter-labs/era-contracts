#!/usr/bin/env bash
# Fork-simulates a plan: starts anvil forked from the network's RPC on a free
# local port, impersonates the sender, and sends every transaction in order
# (execute.sh --mode impersonate). Every one must succeed.
#
#   simulate.sh --plan-dir DIR [--out DIR/simulation] [--fork-block N]
#
# FORK_RPC_URL overrides the RPC from config.json, e.g. an archive node when
# --fork-block is older than the public node keeps state for. The fork URL
# appears in anvil.log, so do not put an API key in it for CI runs.
#
# Only the anvil process started here is stopped at exit.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

plan_dir="" out="" fork_block=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan-dir) plan_dir="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --fork-block) fork_block="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$plan_dir/plan.json" ] || die "usage: simulate.sh --plan-dir DIR [--out DIR] [--fork-block N] (DIR/plan.json from resolve.sh)"
out="${out:-$plan_dir/simulation}"
check_foundry
require_cmd "$ANVIL"
mkdir -p "$out"

network="$(jq -r .network "$plan_dir/plan.json")"
chain_id="$(jq -r .chainId "$plan_dir/plan.json")"
fork_url="${FORK_RPC_URL:-$(rpc_of_network "$network")}"

anvil_args=(--fork-url "$fork_url" --host 127.0.0.1)
if [ -n "$fork_block" ]; then
  [[ "$fork_block" =~ ^[0-9]{1,12}$ ]] || die "fork block must be a block number, got: '$fork_block'"
  anvil_args+=(--fork-block-number "$fork_block")
fi

port="$(find_free_port "$FIRST_ANVIL_PORT")"
local_rpc="http://127.0.0.1:$port"
"$ANVIL" "${anvil_args[@]}" --port "$port" >"$out/anvil.log" 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid" 2>/dev/null || true; wait "$anvil_pid" 2>/dev/null || true' EXIT
log "anvil (pid $anvil_pid) forking $network on $local_rpc${fork_block:+ at block $fork_block}"
wait_for_rpc "$local_rpc" "$anvil_pid"
require_chain_id "$local_rpc" "$chain_id"

forked_at="$("$CAST" block-number --rpc-url "$local_rpc")"
jq -n --arg net "$network" --argjson b "$forked_at" --arg req "${fork_block:-latest}" \
  '{network: $net, forkBlock: $b, requested: $req}' >"$out/fork.json"

rc=0
"$(dirname "$0")/execute.sh" --plan "$plan_dir/plan.json" --mode impersonate --rpc-url "$local_rpc" --out "$out" || rc=$?
printf '\nForked %s at block %s.\n' "$network" "$forked_at" >>"$out/results.md"
exit "$rc"
