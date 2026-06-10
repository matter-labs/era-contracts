#!/usr/bin/env bash
#
# atomic-os-demo.sh — one-touch driver for the L1-free atomic-interop demo on two local
# ZKsync OS servers. Wraps the full runbook in `atomic-imt-server-demo.md` into three commands:
#
#   ./atomic-os-demo.sh update-server   # zk-deployer bootstrap/apply + genesis + server configs
#   ./atomic-os-demo.sh launch          # start Anvil + both servers, deploy L1 registry,
#                                        # fund wallets via L1->L2, start the root relayer daemon
#   ./atomic-os-demo.sh demo            # register a sample 2-leg swap, commit both sides,
#                                        # wait for relay, authorize (+ try execute)
#
#   ./atomic-os-demo.sh status          # show running processes + key addresses
#   ./atomic-os-demo.sh stop            # stop the servers, relayer and Anvil started by `launch`
#
# Everything reuses the same constants (RPCs, chain ids, rich/relayer PK) and a single work
# directory, so the steps are repeatable and compose without following the long guide.
#
# Required tool locations (set in the environment or in a `atomic-os-demo.env` next to this
# script). Defaults assume sibling checkouts under $HOME.
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
# deployer, the relayer and the swap depositor. The recipient is Anvil account #1.
RICH_PK="${RICH_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
RECIPIENT="${RECIPIENT:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

L1_RPC="${L1_RPC:-http://127.0.0.1:8545}"
CHAIN_A_ID="${CHAIN_A_ID:-6565}"
CHAIN_B_ID="${CHAIN_B_ID:-6566}"
CHAIN_A_RPC="${CHAIN_A_RPC:-http://127.0.0.1:3050}"
CHAIN_B_RPC="${CHAIN_B_RPC:-http://127.0.0.1:3150}"
RELAYER_POLL="${RELAYER_POLL:-4}"

# Well-known L2 predeploy addresses for the atomic-interop contracts (genesis).
TREE_ADDR="0x0000000000000000000000000000000000010012"
IMPORTER_ADDR="0x0000000000000000000000000000000000010013"
ESCROW_ADDR="0x0000000000000000000000000000000000010014"

CAST="${CAST:-cast}"
FORGE="${FORGE:-forge}"

# ──────────────────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then C_B="\033[1m"; C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_C="\033[36m"; C_0="\033[0m"
else C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""; fi
_STEP=0
section() { echo ""; echo -e "${C_B}${C_C}══▶ $*${C_0}"; }
step()    { _STEP=$((_STEP+1)); echo -e "${C_B}  [$_STEP] $*${C_0}"; }
info()    { echo -e "      $*"; }
ok()      { echo -e "      ${C_G}✓${C_0} $*"; }
warn()    { echo -e "      ${C_Y}!${C_0} $*"; }
die()     { echo -e "${C_R}✗ $*${C_0}" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────────────────
need_tool() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }
need_file() { [ -e "$1" ] || die "$2 not found: $1 (set $3)"; }

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
registry()  { cat "$WORKDIR/registry.txt"; }

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
  - { name: chain-a, chain_id: $CHAIN_A_ID, role: l1_settling, base_token: eth, da_mode: no_da, skip_priority_txs: true }
  - { name: chain-b, chain_id: $CHAIN_B_ID, role: l1_settling, base_token: eth, da_mode: no_da, skip_priority_txs: true }
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

  step "Verifying the 3 atomic-interop predeploys are in genesis.json"
  for a in 10012 10013 10014; do
    c=$(grep -c "00000000000000000000000000000000000$a" "$WORKDIR/genesis.json" || true)
    [ "$c" -ge 1 ] || die "predeploy 0x$a missing from genesis.json (is the deployer's genesis consts.rs patched?)"
  done
  ok "tree/importer/escrow present in genesis"

  step "zk-deployer apply (register chain-a and chain-b)"
  ( cd "$WORKDIR" && "$ZK_DEPLOYER" apply --broadcast >apply.log 2>&1 ) \
    || { tail -20 "$WORKDIR/apply.log"; die "apply failed"; }
  ok "chain-a $(json_get "$WORKDIR/state.json" "['steps']['chain.init.chain-a']['diamond_proxy']")"
  ok "chain-b $(json_get "$WORKDIR/state.json" "['steps']['chain.init.chain-b']['diamond_proxy']")"

  step "Generating + patching server configs (Validium pubdata, chain-b ports)"
  ( cd "$WORKDIR"
    "$ZK_DEPLOYER" server-config --chain chain-a --output chainA.yaml >/dev/null
    "$ZK_DEPLOYER" server-config --chain chain-b --output chainB.yaml >/dev/null
    sed -i 's/pubdata_mode: .*/pubdata_mode: Validium/' chainA.yaml chainB.yaml
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
# launch: start Anvil + both servers, deploy L1 registry, fund wallets, start relayer
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_launch() {
  section "launch — bring up Anvil, both ZKsync OS servers, the L1 registry and the relayer"
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

  step "Sanity: atomic-interop predeploys initialized on both chains"
  for rpc in "$CHAIN_A_RPC" "$CHAIN_B_RPC"; do
    local tree; tree=$(cq call "$ESCROW_ADDR" 'commitmentTree()(address)' --rpc-url "$rpc")
    [ "${tree,,}" = "${TREE_ADDR,,}" ] || die "escrow not initialized on $rpc (commitmentTree=$tree)"
  done
  ok "escrow ⇄ tree ⇄ importer wired on both chains"

  local BH; BH=$(bridgehub)
  step "Deploying L1 GlobalInteropIMT registry (bridgehub $BH)"
  local REG
  REG=$( cd "$L1_CONTRACTS" && $FORGE create contracts/atomic-interop/GlobalInteropIMT.sol:GlobalInteropIMT \
           --rpc-url "$L1_RPC" --private-key "$RICH_PK" --broadcast --constructor-args "$BH" 2>/dev/null \
         | grep 'Deployed to:' | awk '{print $3}' )
  [ -n "$REG" ] || die "registry deployment failed"
  echo "$REG" > "$WORKDIR/registry.txt"
  ok "registry $REG (chainDiamond($CHAIN_A_ID)=$(cq call "$REG" 'chainDiamond(uint256)(address)' "$CHAIN_A_ID" --rpc-url "$L1_RPC"))"

  step "Funding the rich/relayer wallet $(rich_addr) on both chains via L1->L2 deposit"
  ( cd "$ANVIL_INTEROP"
    npx ts-node fund-l2.ts --l1-rpc "$L1_RPC" --l2-rpc "$CHAIN_A_RPC" --bridgehub "$BH" --chain-id "$CHAIN_A_ID" --recipient "$(rich_addr)" --amount 1000 >/dev/null
    npx ts-node fund-l2.ts --l1-rpc "$L1_RPC" --l2-rpc "$CHAIN_B_RPC" --bridgehub "$BH" --chain-id "$CHAIN_B_ID" --recipient "$(rich_addr)" --amount 1000 >/dev/null )
  ok "depositor funded on chain-a and chain-b"

  step "Writing relayer.json"
  cat > "$WORKDIR/relayer.json" <<JSON
{
  "l1Rpc": "$L1_RPC",
  "registry": "$REG",
  "privateKey": "$RICH_PK",
  "chains": [
    { "chainId": $CHAIN_A_ID, "rpc": "$CHAIN_A_RPC", "tree": "$TREE_ADDR", "importer": "$IMPORTER_ADDR" },
    { "chainId": $CHAIN_B_ID, "rpc": "$CHAIN_B_RPC", "tree": "$TREE_ADDR", "importer": "$IMPORTER_ADDR" }
  ]
}
JSON
  ok "relayer.json written"

  step "Starting the root relayer daemon (poll ${RELAYER_POLL}s)"
  ( cd "$ANVIL_INTEROP" && nohup npx ts-node atomic-root-relayer.ts \
      --config "$WORKDIR/relayer.json" --poll "$RELAYER_POLL" >"$WORKDIR/relayer.log" 2>&1 & echo $! > "$WORKDIR/relayer.pid" )
  sleep 6
  grep -q "cycle complete" "$WORKDIR/relayer.log" || warn "relayer first cycle not confirmed yet (see relayer.log)"
  ok "relayer running (pid $(cat "$WORKDIR/relayer.pid"))"
  echo ""; ok "launch complete — now run: $0 demo"
}

# ──────────────────────────────────────────────────────────────────────────────────────────
# demo: sample 2-leg atomic swap (register -> commit both -> wait relay -> authorize -> execute)
# ──────────────────────────────────────────────────────────────────────────────────────────
cmd_demo() {
  section "demo — drive a sample two-leg atomic swap ($CHAIN_A_ID ⇄ $CHAIN_B_ID)"
  need_file "$WORKDIR/relayer.json" "relayer.json" "run launch first"
  need_tool "$FORGE"; need_tool "$CAST"; need_tool npx
  local REG; REG=$(registry); local DEP; DEP=$(rich_addr)
  local STATE="$WORKDIR/atomic-flow-state.json"
  # The flow CLI expects the command as the first arg; flags (incl. --state) come after.
  flowcli() { ( cd "$ANVIL_INTEROP" && npx ts-node atomic-flow-cli.ts "$@" --state "$STATE" ); }

  # Encode the origin token's (name,symbol,decimals) so the destination NTV can deploy the
  # bridged token on first mint. Format: 0x01 || abi.encode(uint256 chainId, bytes name,
  # bytes symbol, bytes decimals) — matches encodeErc20Data in src/helpers/dummy-flow-helpers.ts.
  erc20_data() { # args: chainId name symbol decimals
    local nb sb db inner
    nb=$($CAST abi-encode "f(string)" "$2" 2>/dev/null)
    sb=$($CAST abi-encode "f(string)" "$3" 2>/dev/null)
    db=$($CAST abi-encode "f(uint8)" "$4" 2>/dev/null)
    inner=$($CAST abi-encode "f(uint256,bytes,bytes,bytes)" "$1" "$nb" "$sb" "$db" 2>/dev/null)
    echo "0x01${inner:2}"
  }

  # Resolve the bridged-token address for a native (originChainId, originToken) on a destination
  # chain, via the destination NTV's tokenAddress(assetId) where assetId = encodeNtvAssetId(...).
  bridged_token() { # args: originChainId originToken destRpc
    local aid
    aid=$( cd "$ANVIL_INTEROP" && npx ts-node -e \
      "import {encodeNtvAssetId} from './src/core/data-encoding'; console.log(encodeNtvAssetId($1,'$2'))" 2>/dev/null )
    cq call 0x0000000000000000000000000000000000010004 'tokenAddress(bytes32)(address)' "$aid" --rpc-url "$3"
  }

  step "Deploying demo ERC20s + minting to $DEP + approving the escrow"
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
    $CAST send "$1" 'mint(address,uint256)'    "$DEP"        1000000000000000000000 --rpc-url "$2" --private-key "$RICH_PK" >/dev/null 2>&1
    $CAST send "$1" 'approve(address,uint256)' "$ESCROW_ADDR" 1000000000000000000000 --rpc-url "$2" --private-key "$RICH_PK" >/dev/null 2>&1
  done
  ok "token-a $TOKA (chain-a), token-b $TOKB (chain-b) — minted + approved"

  step "Seeding the flow-state config (L1 registry + per-chain addresses)"
  cat > "$STATE" <<JSON
{
  "config": {
    "l1": { "rpc": "$L1_RPC", "registry": "$REG" },
    "chains": {
      "$CHAIN_A_ID": { "rpc": "$CHAIN_A_RPC", "escrow": "$ESCROW_ADDR", "tree": "$TREE_ADDR", "importer": "$IMPORTER_ADDR" },
      "$CHAIN_B_ID": { "rpc": "$CHAIN_B_RPC", "escrow": "$ESCROW_ADDR", "tree": "$TREE_ADDR", "importer": "$IMPORTER_ADDR" }
    }
  },
  "flows": {}
}
JSON
  ok "config seeded ($STATE)"

  step "Registering the swap flow (leg A: a→b 100 DEMO, leg B: b→a 50 DEMO)"
  local ERC20DATA_A ERC20DATA_B
  ERC20DATA_A=$(erc20_data "$CHAIN_A_ID" "DemoToken" "DEMO" 18)
  ERC20DATA_B=$(erc20_data "$CHAIN_B_ID" "DemoToken" "DEMO" 18)
  cat > "$WORKDIR/legs.json" <<JSON
[
  { "originChainId": $CHAIN_A_ID, "depositor": "$DEP", "originToken": "$TOKA", "amount": "100",
    "destChainId": $CHAIN_B_ID, "recipient": "$RECIPIENT", "erc20Data": "$ERC20DATA_A" },
  { "originChainId": $CHAIN_B_ID, "depositor": "$DEP", "originToken": "$TOKB", "amount": "50",
    "destChainId": $CHAIN_A_ID, "recipient": "$RECIPIENT", "erc20Data": "$ERC20DATA_B" }
]
JSON
  flowcli register-flow-id --legs-file "$WORKDIR/legs.json" >/dev/null
  local FLOWID LEG_A LEG_B
  FLOWID=$(python3 -c "import json;print(list(json.load(open('$STATE'))['flows'])[-1])")
  LEG_A=$(python3 -c "import json;f=json.load(open('$STATE'))['flows']['$FLOWID'];print([l['legId'] for l in f['legs'] if l['spec']['originChainId']==$CHAIN_A_ID][0])")
  LEG_B=$(python3 -c "import json;f=json.load(open('$STATE'))['flows']['$FLOWID'];print([l['legId'] for l in f['legs'] if l['spec']['originChainId']==$CHAIN_B_ID][0])")
  ok "flowId $FLOWID"

  step "Committing both legs on their origin chains (ERC20 escrow + IMT insert)"
  flowcli commit-send "$FLOWID" "$LEG_A" "$RICH_PK" "$CHAIN_A_RPC" | sed 's/^/      /'
  flowcli commit-send "$FLOWID" "$LEG_B" "$RICH_PK" "$CHAIN_B_RPC" | sed 's/^/      /'

  step "Authorizing the flow on both chains (verifies the IMT inclusion proofs)"
  # The relayer daemon needs one poll cycle to expose the post-commit roots to L1 and import the
  # resulting global root back; retry authorize until that proof is available.
  flowcli check-status "$FLOWID" >/dev/null  # sanity
  local attempt=0
  until flowcli authorize "$FLOWID" "$RICH_PK" "$CHAIN_B_RPC" >"$WORKDIR/authorize-b.log" 2>&1; do
    attempt=$((attempt+1)); [ "$attempt" -gt 15 ] && { cat "$WORKDIR/authorize-b.log"; die "authorize did not succeed (relayer/proof not ready)"; }
    sleep "$RELAYER_POLL"
  done
  sed 's/^/      /' "$WORKDIR/authorize-b.log"
  flowcli authorize "$FLOWID" "$RICH_PK" "$CHAIN_A_RPC" 2>&1 | sed 's/^/      /'
  ok "both chains authorized — every spec verified (remote legs via IMT inclusion proof, local via local state)"

  step "Spec states (2 = Executable) — leg A / leg B"
  info "chain-a: $(cq call "$ESCROW_ADDR" 'specState(bytes32,bytes32)(uint8)' "$FLOWID" "$LEG_A" --rpc-url "$CHAIN_A_RPC") / $(cq call "$ESCROW_ADDR" 'specState(bytes32,bytes32)(uint8)' "$FLOWID" "$LEG_B" --rpc-url "$CHAIN_A_RPC")    chain-b: $(cq call "$ESCROW_ADDR" 'specState(bytes32,bytes32)(uint8)' "$FLOWID" "$LEG_A" --rpc-url "$CHAIN_B_RPC") / $(cq call "$ESCROW_ADDR" 'specState(bytes32,bytes32)(uint8)' "$FLOWID" "$LEG_B" --rpc-url "$CHAIN_B_RPC")"

  step "Executing all four sides (source burn + destination mint for each leg)"
  flowcli execute "$FLOWID" "$LEG_A" "$RICH_PK" "$CHAIN_A_RPC" | sed 's/^/      /'   # leg A source burn (chain-a)
  flowcli execute "$FLOWID" "$LEG_A" "$RICH_PK" "$CHAIN_B_RPC" | sed 's/^/      /'   # leg A dest mint (chain-b)
  flowcli execute "$FLOWID" "$LEG_B" "$RICH_PK" "$CHAIN_B_RPC" | sed 's/^/      /'   # leg B source burn (chain-b)
  flowcli execute "$FLOWID" "$LEG_B" "$RICH_PK" "$CHAIN_A_RPC" | sed 's/^/      /'   # leg B dest mint (chain-a)
  ok "all four execute calls landed"

  step "Verifying balances — recipient received bridged tokens, source escrows debited"
  local bridgedA bridgedB
  bridgedA=$(bridged_token "$CHAIN_A_ID" "$TOKA" "$CHAIN_B_RPC")   # token-a bridged onto chain-b
  bridgedB=$(bridged_token "$CHAIN_B_ID" "$TOKB" "$CHAIN_A_RPC")   # token-b bridged onto chain-a
  local recvA recvB escA escB
  recvA=$(cq call "$bridgedA" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$CHAIN_B_RPC")
  recvB=$(cq call "$bridgedB" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$CHAIN_A_RPC")
  escA=$(cq call "$TOKA" 'balanceOf(address)(uint256)' "$ESCROW_ADDR" --rpc-url "$CHAIN_A_RPC")
  escB=$(cq call "$TOKB" 'balanceOf(address)(uint256)' "$ESCROW_ADDR" --rpc-url "$CHAIN_B_RPC")
  info "recipient on chain-b: ${recvA%% *} bridged DEMO (token-a)   [expect 100]"
  info "recipient on chain-a: ${recvB%% *} bridged DEMO (token-b)   [expect 50]"
  info "source escrow on chain-a: ${escA%% *} token-a   on chain-b: ${escB%% *} token-b   [expect 0 / 0]"
  if [ "${recvA%% *}" = "100" ] && [ "${recvB%% *}" = "50" ] && [ "${escA%% *}" = "0" ] && [ "${escB%% *}" = "0" ]; then
    ok "atomic swap settled: funds received on both destinations, source escrows burned"
  else
    die "balance check failed — see values above"
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
  [ -f "$WORKDIR/registry.txt" ] && info "registry: $(registry)"
  for p in anvil serverA serverB relayer; do
    [ -f "$WORKDIR/$p.pid" ] && kill -0 "$(cat "$WORKDIR/$p.pid")" 2>/dev/null && info "$p running (pid $(cat "$WORKDIR/$p.pid"))" || true
  done
}

cmd_stop() {
  section "stop — terminating processes started by launch"
  for p in relayer serverA serverB anvil; do
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
