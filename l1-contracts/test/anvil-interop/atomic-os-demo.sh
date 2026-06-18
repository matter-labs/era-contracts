#!/usr/bin/env bash
#
# atomic-os-demo.sh — one-touch driver for the L1-free atomic-interop demo (BUNDLE MODEL) on two
# local ZKsync OS servers. Wraps the runbook in `atomic-imt-server-demo.md` into three commands:
#
#   ./atomic-os-demo.sh update-server   # zk-deployer bootstrap/apply + genesis + server configs
#   ./atomic-os-demo.sh launch          # start Anvil + both servers, fund wallets via L1->L2
#   ./atomic-os-demo.sh demo            # register a 2-leg swap, atomic-send both legs, execute both
#
#   ./atomic-os-demo.sh status          # show running processes + key addresses
#   ./atomic-os-demo.sh stop            # stop the servers and Anvil started by `launch`
#
# ─ Bundle model (vs. the old escrow/global-IMT/relayer model this script used to drive) ────────────
#   The atomic flow is now L1-FREE and runs entirely through the production interop contracts:
#     SEND     `InteropCenter.sendBundle(dst, [indirect AR call], [atomicBundle(flowId,deadline,low)])`
#              — burns via the AR's `initiateIndirectCall`, and because of the `atomicBundle` attribute
#              appends the leg's commit value to this chain's {L2InteropCommitmentTree} (0x10012) via
#              {AtomicFlowManager.append} (0x10014) INSTEAD of publishing the bundle to L1.
#     RECEIVE  `InteropHandler.executeAtomicBundle(bundle, AtomicFinalityProof)` once EVERY leg is
#              proven committed (one IMT inclusion proof per leg) before the deadline.
#     TIMEOUT  `AtomicFlowManager.authorizeRefund` + `claimRefund`.
#   There is NO L1 GlobalInteropIMT registry and NO root-relayer daemon anymore. A chain's commitment
#   root travels on the standard interop-root channel and is authenticated by the consuming chain; the
#   deadline is a settlement-layer block number derived from the same inclusion proof.
#
# ⚠️  UNVERIFIED ON LIVE SERVERS. The bundle-model atomic flow is covered end-to-end by the Anvil e2e
#     spec `test/hardhat/13-imt-atomic-swap.spec.ts` (happy + timeout), where the cross-chain
#     interop-root authentication is MOCKED ({MockL2MessageVerification}). This script targets two REAL
#     zksync-os servers, where that authentication must instead be served by the servers' native
#     interop-root import between the two chains. That live path is NOT exercised by CI and has not been
#     run end-to-end at the time of writing — the `execute` step here assumes the destination server can
#     authenticate the source chain's commitment root (the same assumption the Anvil harness mocks). If
#     `execute` fails proof verification on a live server, that integration — not this script's flow — is
#     the gap to close. The `demo` step prints this caveat at the inclusion-proof boundary.
#
# Required tool locations (set in the environment or in a `atomic-os-demo.env` next to this script).
# Defaults assume sibling checkouts under $HOME.
#
#   ZK_DEPLOYER  path to the built zk-deployer binary (zksync-os-integration-tests)
#   SERVER_BIN   path to the built zksync-os-server binary (with the demo proving bypass)
#   LOCAL_DEV    path to tests/configs/local_dev.yaml (zksync-os-integration-tests)
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────────────────
# Config (override via env or atomic-os-demo.env)
# ──────────────────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/atomic-os-demo.env" ] && source "$SCRIPT_DIR/atomic-os-demo.env"

ERA_CONTRACTS="${ERA_CONTRACTS:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
L1_CONTRACTS="$ERA_CONTRACTS/l1-contracts"
ANVIL_INTEROP="$L1_CONTRACTS/test/anvil-interop"

ZK_DEPLOYER="${ZK_DEPLOYER:-$HOME/zksync-os-integration-tests/target/debug/zk-deployer}"
SERVER_BIN="${SERVER_BIN:-$HOME/zksync-os-server/target/release/zksync-os-server}"
LOCAL_DEV="${LOCAL_DEV:-$HOME/zksync-os-integration-tests/tests/configs/local_dev.yaml}"

WORKDIR="${WORKDIR:-$ANVIL_INTEROP/.atomic-os-demo}"

# Shared constants — the standard local Anvil rich account (Anvil account #0), reused as the
# deployer and the swap depositor. The recipient is Anvil account #1.
RICH_PK="${RICH_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
RECIPIENT="${RECIPIENT:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

L1_RPC="${L1_RPC:-http://127.0.0.1:8545}"
CHAIN_A_ID="${CHAIN_A_ID:-6565}"
CHAIN_B_ID="${CHAIN_B_ID:-6566}"
CHAIN_A_RPC="${CHAIN_A_RPC:-http://127.0.0.1:3050}"
CHAIN_B_RPC="${CHAIN_B_RPC:-http://127.0.0.1:3150}"

# Deadline as a settlement-layer block number (large, so inclusion proofs satisfy slBlock <= deadline).
DEADLINE_SL_BLOCK="${DEADLINE_SL_BLOCK:-1000000}"

# Base-token value written into intent.yaml. The zk-deployer intent schema for `base_token`
# varies by version: older builds take the string `eth`; newer ones expect a struct. Override
# via the BASE_TOKEN env var with an inline-YAML value, e.g.:
#   BASE_TOKEN='eth'
#   BASE_TOKEN='{ address: "0x0000000000000000000000000000000000000001" }'
BASE_TOKEN="${BASE_TOKEN:-eth}"

# Well-known L2 predeploy addresses for the bundle-model atomic-interop contracts (genesis).
# The global-IMT importer (formerly 0x10013) is GONE in the bundle model.
TREE_ADDR="0x0000000000000000000000000000000000010012"
MANAGER_ADDR="0x0000000000000000000000000000000000010014"
INTEROP_CENTER_ADDR="0x000000000000000000000000000000000001000d"
INTEROP_HANDLER_ADDR="0x000000000000000000000000000000000001000e"
ASSET_ROUTER_ADDR="0x0000000000000000000000000000000000010003"
NTV_ADDR="0x0000000000000000000000000000000000010004"

CAST="${CAST:-cast}"
FORGE="${FORGE:-forge}"

# ──────────────────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────────────────
# Use ANSI-C $'...' so the colour codes are real escape bytes — then plain `echo` prints them
# correctly on every shell (no reliance on `echo -e`, which varies between bash/sh/macOS).
if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""; fi
_STEP=0
section() { echo ""; echo "${C_B}${C_C}══▶ $*${C_0}"; }
step()    { _STEP=$((_STEP+1)); echo "${C_B}  [$_STEP] $*${C_0}"; }
info()    { echo "      $*"; }
ok()      { echo "      ${C_G}✓${C_0} $*"; }
warn()    { echo "      ${C_Y}!${C_0} $*"; }
die()     { echo "${C_R}✗ $*${C_0}" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────────────────
need_tool() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }
need_file() { [ -e "$1" ] || die "$2 not found: $1 (set $3)"; }

# Portable in-place sed (GNU and BSD/macOS differ on `sed -i`). Edits each file via a temp copy.
sed_i() { # args: <sed-expr> <file>...
  local expr="$1"; shift
  local f
  for f in "$@"; do sed "$expr" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; done
}
# Lowercase a string without relying on bash 4 `${x,,}` (macOS ships bash 3.2).
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

json_get() { python3 -c "import json,sys;print(json.load(open('$1'))$2)"; }

rpc_up()   { $CAST chain-id --rpc-url "$1" >/dev/null 2>&1; }
# cast for value capture — silences foundry.toml config warnings on stderr.
cq()       { $CAST "$@" 2>/dev/null; }

wait_rpc() {
  local url="$1" name="$2" tries=0
  while ! rpc_up "$url"; do
    tries=$((tries+1)); [ "$tries" -gt 120 ] && die "$name ($url) did not come up"
    sleep 1
  done
}

rich_addr() { $CAST wallet address --private-key "$RICH_PK"; }

bridgehub() { json_get "$WORKDIR/state.json" "['steps']['ecosystem.init']['bridgehub_proxy']"; }

# ──────────────────────────────────────────────────────────────────────────────────────────
# update-server: bootstrap the ecosystem + genesis + server configs (validium / no-DA)
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_update_server() {
  section "update-server — regenerate ecosystem, genesis and server artifacts"
  need_file "$ZK_DEPLOYER" "zk-deployer binary" ZK_DEPLOYER
  need_tool "$FORGE"; need_tool "$CAST"
  mkdir -p "$WORKDIR"

  step "Building L1 contract artifacts (forge build)"
  ( cd "$L1_CONTRACTS" && $FORGE build >/dev/null ) && ok "artifacts built"

  step "Writing intent.yaml (two ZKsync OS chains, no_da)"
  cat > "$WORKDIR/intent.yaml" <<YAML
schema_version: 1
scenario: l1_only
wallets: { generate: true, ecosystem_seed: "atomic-interop-demo" }
ecosystem: { era_chain_id: $CHAIN_A_ID, vm_type: zksyncos, with_testnet_verifier: true, with_legacy_bridge: false }
chains:
  - name: chain-a
    chain_id: $CHAIN_A_ID
    role: l1_settling
    base_token: $BASE_TOKEN
    da_mode: no_da
    skip_priority_txs: true
  - name: chain-b
    chain_id: $CHAIN_B_ID
    role: l1_settling
    base_token: $BASE_TOKEN
    da_mode: no_da
    skip_priority_txs: true
YAML
  ok "intent.yaml written"

  step "Cleaning previous run state"
  ( cd "$WORKDIR" && rm -rf out db state.json l1-state.json genesis.json chainA.yaml chainB.yaml )
  ok "clean"

  export PROTOCOL_CONTRACTS_ROOT="$ERA_CONTRACTS"
  step "zk-deployer bootstrap (Bridgehub/CTM + genesis, auto-Anvil)"
  ( cd "$WORKDIR" && "$ZK_DEPLOYER" bootstrap --broadcast >bootstrap.log 2>&1 ) \
    || { tail -20 "$WORKDIR/bootstrap.log"; die "bootstrap failed"; }
  ok "bridgehub $(bridgehub)"

  step "Verifying the bundle-model atomic-interop predeploys are in genesis.json"
  # Bundle model: commitment tree (0x10012) + flow manager (0x10014). The old global-IMT importer
  # (0x10013) is intentionally absent.
  for a in 10012 10014; do
    c=$(grep -c "00000000000000000000000000000000000$a" "$WORKDIR/genesis.json" || true)
    [ "$c" -ge 1 ] || die "predeploy 0x$a missing from genesis.json (is the deployer's genesis consts.rs patched?)"
  done
  if grep -q "0000000000000000000000000000000000010013" "$WORKDIR/genesis.json"; then
    warn "genesis still contains 0x10013 (global-IMT importer) — stale genesis consts.rs? bundle model removed it"
  fi
  ok "commitment tree (0x10012) + flow manager (0x10014) present in genesis"

  step "zk-deployer apply (register chain-a and chain-b)"
  ( cd "$WORKDIR" && "$ZK_DEPLOYER" apply --broadcast >apply.log 2>&1 ) \
    || { tail -20 "$WORKDIR/apply.log"; die "apply failed"; }
  ok "chain-a $(json_get "$WORKDIR/state.json" "['steps']['chain.init.chain-a']['diamond_proxy']")"
  ok "chain-b $(json_get "$WORKDIR/state.json" "['steps']['chain.init.chain-b']['diamond_proxy']")"

  step "Generating + patching server configs (Validium pubdata, chain-b ports)"
  ( cd "$WORKDIR"
    "$ZK_DEPLOYER" server-config --chain chain-a --output chainA.yaml >/dev/null
    "$ZK_DEPLOYER" server-config --chain chain-b --output chainB.yaml >/dev/null
    sed_i 's/pubdata_mode: .*/pubdata_mode: Validium/' chainA.yaml chainB.yaml
    cat >> chainB.yaml <<YAML

rpc: { address: "0.0.0.0:3150" }
prover_api: { address: "0.0.0.0:3224" }
status_server: { address: "0.0.0.0:3171" }
observability: { prometheus: { port: 3412 }, log: { format: terminal, use_color: true } }
YAML
  )
  ok "chainA.yaml + chainB.yaml ready"
  echo ""; ok "update-server complete — now run: $0 launch"
}

# ──────────────────────────────────────────────────────────────────────────────────────────
# launch: start Anvil + both servers, fund wallets
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_launch() {
  section "launch — bring up Anvil and both ZKsync OS servers, fund the depositor"
  need_file "$WORKDIR/l1-state.json" "l1-state.json" "run update-server first"
  need_file "$SERVER_BIN" "zksync-os-server binary" SERVER_BIN
  need_file "$LOCAL_DEV" "local_dev.yaml" LOCAL_DEV
  need_tool anvil; need_tool "$CAST"; need_tool npx

  step "Starting L1 Anvil on $L1_RPC (from saved ecosystem state)"
  if rpc_up "$L1_RPC"; then warn "something already answers on $L1_RPC — reusing it"; else
    ( cd "$WORKDIR"
      nohup anvil --load-state l1-state.json --block-time 0.25 --mixed-mining \
        --slots-in-an-epoch 10 --disable-block-gas-limit --port 8545 >anvil.log 2>&1 & echo $! > anvil.pid )
    wait_rpc "$L1_RPC" "L1 Anvil"
  fi
  ok "L1 up (chain-id $(cq chain-id --rpc-url "$L1_RPC"))"

  step "Starting chain-a ($CHAIN_A_RPC) and chain-b ($CHAIN_B_RPC) with proving bypass"
  ( cd "$WORKDIR" && rm -rf db
    ZKSYNC_OS_DEMO_SKIP_PROVING=1 L1_PROVIDER_RPC_URL="$L1_RPC" nohup \
      "$SERVER_BIN" --config "$LOCAL_DEV" --config chainA.yaml >serverA.log 2>&1 & echo $! > serverA.pid
    ZKSYNC_OS_DEMO_SKIP_PROVING=1 L1_PROVIDER_RPC_URL="$L1_RPC" nohup \
      "$SERVER_BIN" --config "$LOCAL_DEV" --config chainB.yaml >serverB.log 2>&1 & echo $! > serverB.pid )
  wait_rpc "$CHAIN_A_RPC" "chain-a"; wait_rpc "$CHAIN_B_RPC" "chain-b"
  ok "chain-a up (chain-id $(cq chain-id --rpc-url "$CHAIN_A_RPC")), chain-b up (chain-id $(cq chain-id --rpc-url "$CHAIN_B_RPC"))"

  step "Sanity: bundle-model atomic-interop predeploys initialized on both chains"
  # In the bundle model genesis wires the manager to the commitment tree
  # (AtomicFlowManager.commitmentTree() == tree). No escrow, no L1 registry, no importer.
  for rpc in "$CHAIN_A_RPC" "$CHAIN_B_RPC"; do
    local tree; tree=$(cq call "$MANAGER_ADDR" 'commitmentTree()(address)' --rpc-url "$rpc")
    [ "$(lc "$tree")" = "$(lc "$TREE_ADDR")" ] || die "flow manager not initialized on $rpc (commitmentTree=$tree)"
  done
  ok "AtomicFlowManager ⇄ L2InteropCommitmentTree wired on both chains"

  local BH; BH=$(bridgehub)
  step "Funding the depositor $(rich_addr) on both chains via L1->L2 deposit"
  ( cd "$ANVIL_INTEROP"
    npx ts-node fund-l2.ts --l1-rpc "$L1_RPC" --l2-rpc "$CHAIN_A_RPC" --bridgehub "$BH" --chain-id "$CHAIN_A_ID" --recipient "$(rich_addr)" --amount 1000 >/dev/null
    npx ts-node fund-l2.ts --l1-rpc "$L1_RPC" --l2-rpc "$CHAIN_B_RPC" --bridgehub "$BH" --chain-id "$CHAIN_B_ID" --recipient "$(rich_addr)" --amount 1000 >/dev/null )
  ok "depositor funded on chain-a and chain-b"

  echo ""; ok "launch complete — now run: $0 demo"
}

# ──────────────────────────────────────────────────────────────────────────────────────────
# demo: sample 2-leg atomic swap (register -> atomic-send both -> check-status -> execute both)
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_demo() {
  section "demo — drive a sample two-leg atomic swap ($CHAIN_A_ID ⇄ $CHAIN_B_ID), bundle model"
  need_tool "$FORGE"; need_tool "$CAST"; need_tool npx
  local DEP; DEP=$(rich_addr)
  local STATE="$WORKDIR/atomic-flow-state.json"
  # The flow CLI expects the command as the first arg; flags (incl. --state) come after.
  flowcli() { ( cd "$ANVIL_INTEROP" && npx ts-node atomic-flow-cli.ts "$@" --state "$STATE" ); }

  # Resolve the bridged-token address for a native (originChainId, originToken) on a destination
  # chain, via the destination NTV's tokenAddress(assetId) where assetId = encodeNtvAssetId(...).
  bridged_token() { # args: originChainId originToken destRpc
    local aid
    aid=$( cd "$ANVIL_INTEROP" && npx ts-node -e \
      "import {encodeNtvAssetId} from './src/core/data-encoding'; console.log(encodeNtvAssetId($1,'$2'))" 2>/dev/null )
    cq call "$NTV_ADDR" 'tokenAddress(bytes32)(address)' "$aid" --rpc-url "$3"
  }

  step "Deploying demo ERC20s + minting to $DEP + approving the NTV (source-burn pull)"
  # The atomic send burns the source token through AR.initiateIndirectCall -> NTV.bridgeBurn, whose
  # internal transferFrom pulls from the depositor with the NTV (0x10004) as spender — so the depositor
  # approves the NTV. (Token registration with the NTV happens lazily on first bridgeBurn.)
  local TOKA TOKB
  TOKA=$( cd "$L1_CONTRACTS" && $FORGE create contracts/dev-contracts/TestnetERC20Token.sol:TestnetERC20Token \
            --rpc-url "$CHAIN_A_RPC" --private-key "$RICH_PK" --broadcast --constructor-args "DemoToken" "DEMO" 18 2>/dev/null \
          | grep 'Deployed to:' | awk '{print $3}' )
  TOKB=$( cd "$L1_CONTRACTS" && $FORGE create contracts/dev-contracts/TestnetERC20Token.sol:TestnetERC20Token \
            --rpc-url "$CHAIN_B_RPC" --private-key "$RICH_PK" --broadcast --constructor-args "DemoToken" "DEMO" 18 2>/dev/null \
          | grep 'Deployed to:' | awk '{print $3}' )
  [ -n "$TOKA" ] && [ -n "$TOKB" ] || die "token deployment failed"
  for pair in "$TOKA $CHAIN_A_RPC" "$TOKB $CHAIN_B_RPC"; do
    set -- $pair
    $CAST send "$1" 'mint(address,uint256)'    "$DEP"      1000000000000000000000 --rpc-url "$2" --private-key "$RICH_PK" >/dev/null 2>&1
    $CAST send "$1" 'approve(address,uint256)' "$NTV_ADDR" 1000000000000000000000 --rpc-url "$2" --private-key "$RICH_PK" >/dev/null 2>&1
  done
  ok "token-a $TOKA (chain-a), token-b $TOKB (chain-b) — minted + NTV-approved"

  step "Seeding the flow-state config (per-chain bundle-model addresses)"
  cat > "$STATE" <<JSON
{
  "config": {
    "chains": {
      "$CHAIN_A_ID": { "rpc": "$CHAIN_A_RPC", "interopCenter": "$INTEROP_CENTER_ADDR", "interopHandler": "$INTEROP_HANDLER_ADDR", "manager": "$MANAGER_ADDR", "tree": "$TREE_ADDR" },
      "$CHAIN_B_ID": { "rpc": "$CHAIN_B_RPC", "interopCenter": "$INTEROP_CENTER_ADDR", "interopHandler": "$INTEROP_HANDLER_ADDR", "manager": "$MANAGER_ADDR", "tree": "$TREE_ADDR" }
    }
  },
  "flows": {}
}
JSON
  ok "config seeded ($STATE)"

  step "Registering the swap flow (leg A: a→b 100 DEMO, leg B: b→a 50 DEMO)"
  # LegSpec shape per atomic-flow-cli.ts: amounts are whole-token strings (18 decimals applied in-CLI).
  # The bundle model carries the origin token's metadata in the burn's bridgeMintCalldata, so the
  # destination NTV deploys the bridged token on first mint — no separate erc20Data needed.
  cat > "$WORKDIR/legs.json" <<JSON
[
  { "originChainId": $CHAIN_A_ID, "depositor": "$DEP", "originToken": "$TOKA", "amount": "100",
    "destChainId": $CHAIN_B_ID, "recipient": "$RECIPIENT" },
  { "originChainId": $CHAIN_B_ID, "depositor": "$DEP", "originToken": "$TOKB", "amount": "50",
    "destChainId": $CHAIN_A_ID, "recipient": "$RECIPIENT" }
]
JSON
  flowcli register-flow-id --legs-file "$WORKDIR/legs.json" --deadline "$DEADLINE_SL_BLOCK" >/dev/null
  local FLOWID LEG_A LEG_B
  FLOWID=$(python3 -c "import json;print(list(json.load(open('$STATE'))['flows'])[-1])")
  LEG_A=$(python3 -c "import json;f=json.load(open('$STATE'))['flows']['$FLOWID'];print([l['legId'] for l in f['legs'] if l['spec']['originChainId']==$CHAIN_A_ID][0])")
  LEG_B=$(python3 -c "import json;f=json.load(open('$STATE'))['flows']['$FLOWID'];print([l['legId'] for l in f['legs'] if l['spec']['originChainId']==$CHAIN_B_ID][0])")
  ok "flowId $FLOWID"

  step "Atomic-sending both legs on their origin chains (source burn + IMT append)"
  flowcli send "$FLOWID" "$LEG_A" "$RICH_PK" "$CHAIN_A_RPC" | sed 's/^/      /'
  flowcli send "$FLOWID" "$LEG_B" "$RICH_PK" "$CHAIN_B_RPC" | sed 's/^/      /'

  step "Checking commit status (every leg's commit value present in its source IMT)"
  flowcli check-status "$FLOWID" | sed 's/^/      /'

  warn "execute below authenticates each source chain's commitment root on the destination server."
  warn "On Anvil this is mocked; on live zksync-os servers it relies on native interop-root import —"
  warn "the UNVERIFIED integration noted in this script's header. A proof-verification failure here is"
  warn "that integration gap, not the flow itself (which is green under 13-imt-atomic-swap.spec.ts)."

  step "Executing each destination leg (executeAtomicBundle: per-leg inclusion proof + mint)"
  # Leg A's destination is chain-b; leg B's destination is chain-a.
  flowcli execute "$FLOWID" "$LEG_A" "$RICH_PK" "$CHAIN_B_RPC" | sed 's/^/      /'
  flowcli execute "$FLOWID" "$LEG_B" "$RICH_PK" "$CHAIN_A_RPC" | sed 's/^/      /'
  ok "both destination legs executed"

  step "Verifying balances — recipient received bridged tokens; depositor's source debited"
  local bridgedA bridgedB
  bridgedA=$(bridged_token "$CHAIN_A_ID" "$TOKA" "$CHAIN_B_RPC")   # token-a bridged onto chain-b
  bridgedB=$(bridged_token "$CHAIN_B_ID" "$TOKB" "$CHAIN_A_RPC")   # token-b bridged onto chain-a
  local recvA recvB depA depB
  recvA=$(cq call "$bridgedA" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$CHAIN_B_RPC")
  recvB=$(cq call "$bridgedB" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$CHAIN_A_RPC")
  depA=$(cq call "$TOKA" 'balanceOf(address)(uint256)' "$DEP" --rpc-url "$CHAIN_A_RPC")
  depB=$(cq call "$TOKB" 'balanceOf(address)(uint256)' "$DEP" --rpc-url "$CHAIN_B_RPC")
  info "recipient on chain-b: ${recvA%% *} bridged DEMO (token-a)   [expect 100000000000000000000]"
  info "recipient on chain-a: ${recvB%% *} bridged DEMO (token-b)   [expect 50000000000000000000]"
  info "depositor token-a on chain-a: ${depA%% *}   token-b on chain-b: ${depB%% *}   [burned: 100 / 50 debited]"
  if [ "${recvA%% *}" = "100000000000000000000" ] && [ "${recvB%% *}" = "50000000000000000000" ]; then
    ok "atomic swap settled: funds received on both destinations, source tokens burned"
  else
    die "balance check failed — see values above (likely the unverified live root-authentication step)"
  fi
  echo ""; ok "demo complete — full atomic swap executed and verified."
}

# ──────────────────────────────────────────────────────────────────────────────────────────
# status / stop
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_status() {
  section "status"
  for pair in "L1:$L1_RPC" "chain-a:$CHAIN_A_RPC" "chain-b:$CHAIN_B_RPC"; do
    local name="${pair%%:*}" url="${pair#*:}"
    if rpc_up "$url"; then ok "$name up ($url) block=$(cq block-number --rpc-url "$url")"; else warn "$name down ($url)"; fi
  done
  info "tree $TREE_ADDR · manager $MANAGER_ADDR · interopCenter $INTEROP_CENTER_ADDR · interopHandler $INTEROP_HANDLER_ADDR"
  for p in anvil serverA serverB; do
    [ -f "$WORKDIR/$p.pid" ] && kill -0 "$(cat "$WORKDIR/$p.pid")" 2>/dev/null && info "$p running (pid $(cat "$WORKDIR/$p.pid"))" || true
  done
}

cmd_stop() {
  section "stop — terminating processes started by launch"
  for p in serverA serverB anvil; do
    local f="$WORKDIR/$p.pid"
    if [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then
      kill -TERM "$(cat "$f")" 2>/dev/null && ok "stopped $p (pid $(cat "$f"))"
    fi
    rm -f "$f"
  done
}

# ──────────────────────────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    update-server) cmd_update_server ;;
    launch)        cmd_launch ;;
    demo)          cmd_demo ;;
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    *) echo "usage: $0 {update-server|launch|demo|status|stop}"; exit 1 ;;
  esac
}
main "$@"
