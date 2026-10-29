#!/usr/bin/env bash
# Starts a local anvil L1 and deploys the era-contracts (v0.35 + L1->L2 deposits via interop) L1 ecosystem
# from this worktree, then registers two ZKsync OS chains (301, 302) settling on L1 with the testnet
# (mock-proof) verifier, a no-DA (Validium / EMPTY_NO_DA) DA pair, interop enabled and each other's
# interop peer. Writes fed-l1/out/addresses.json and an anvil state dump. See fed-l1/README.md.
#
# Env knobs (all optional):
#   FED_L1_PORT                    anvil port (default 8545)
#   FED_L1_CHAIN_ID                anvil chain id (default 31337)
#   FED_GENESIS_BATCH_HASH         batch 0 StoredBatchInfo.batchHash (genesis state commitment) of the
#                                  CTM release; default: ZKsync OS genesis_root from configs/genesis/zksync-os/latest.json
#   FED_GENESIS_ROLLUP_LEAF_INDEX  batch 0 StoredBatchInfo.indexRepeatedStorageChanges (default 0)
#   FED_GENESIS_BATCH_COMMITMENT   only accepted if equal to 0x..01: the contracts hard-code it
#   FED_DUMMY_MESSAGE_ROOT=1       deploy DummyL1MessageRoot (skips L2->L1 Merkle proof checks) instead of L1MessageRoot
#   FED_SKIP_SMOKE=1               skip the snapshot/settle/revert smoke test of batch 1
#   FED_KEEP_ANVIL=0               stop anvil at the end (default: leave it running)
set -euo pipefail

FED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FED_DIR/.." && pwd)"
L1C="$REPO_ROOT/l1-contracts"
OUT="$FED_DIR/out"
# forge's fs_permissions only allow writes under l1-contracts/script-out (gitignored), so script
# configs/outputs live there; everything the host needs is copied into fed-l1/out.
WORK_REL="/script-out/fed-l1"
WORK="$L1C$WORK_REL"
TOMLGET="python3 $FED_DIR/scripts/tomlget.py"

PORT="${FED_L1_PORT:-8545}"
L1_CHAIN_ID="${FED_L1_CHAIN_ID:-31337}"
RPC="http://127.0.0.1:$PORT"
CHAINS=(301 302)

# anvil default mnemonic keys
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # #0: owner of everything, chain admin
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ALICE_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d      # #1: Alice, 1000 USDC
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a        # #2: Bob, 1000 DAI
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
OPERATOR_PK_301=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a  # #4: chain 301 validator
OPERATOR_301=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
OPERATOR_PK_302=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba  # #5: chain 302 validator
OPERATOR_302=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
TOKEN_AMOUNT=1000000000000000000000   # 1000 * 1e18

ETH_TOKEN_ADDRESS=0x0000000000000000000000000000000000000001
L2_DA_COMMITMENT_SCHEME_EMPTY_NO_DA=1
CREATE2_FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
send() { cast send --rpc-url "$RPC" "$@" >/dev/null; }
call() { cast call --rpc-url "$RPC" "$@"; }

if [[ -n "${FED_GENESIS_BATCH_COMMITMENT:-}" ]]; then
  [[ "$(cast to-uint256 "$FED_GENESIS_BATCH_COMMITMENT")" == "$(cast to-uint256 1)" ]] ||
    die "FED_GENESIS_BATCH_COMMITMENT must be 1: ChainTypeManager.storedBatchZero hard-codes GENESIS_BATCH_COMMITMENT"
fi
if [[ -n "${FED_GENESIS_BATCH_HASH:-}" ]]; then
  [[ "$FED_GENESIS_BATCH_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "FED_GENESIS_BATCH_HASH must be a 0x-prefixed bytes32"
  [[ "$(cast to-uint256 "$FED_GENESIS_BATCH_HASH")" != "0" ]] || die "FED_GENESIS_BATCH_HASH must be non-zero"
fi
export FED_GENESIS_BATCH_HASH="${FED_GENESIS_BATCH_HASH:-}"
export FED_GENESIS_ROLLUP_LEAF_INDEX="${FED_GENESIS_ROLLUP_LEAF_INDEX:-0}"

mkdir -p "$OUT" "$WORK"
rm -f "$WORK"/*.toml "$WORK"/*.txt "$WORK"/*.sol

# ───────────────────────────── anvil ─────────────────────────────
log "Starting anvil on :$PORT (chain id $L1_CHAIN_ID)"
if [[ -f "$OUT/anvil.pid" ]] && kill -0 "$(cat "$OUT/anvil.pid")" 2>/dev/null; then
  kill "$(cat "$OUT/anvil.pid")"; sleep 1
fi
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  die "something is already listening on $RPC; stop it or set FED_L1_PORT"
fi
rm -f "$OUT/state.json"
# Same settings as the repo's anvil-interop harness (test/anvil-interop/src/daemons/anvil-manager.ts):
# 100M block gas limit, zero base fee, auto-impersonation. Automine (no --block-time).
# Anvil's clock starts at wall time: Committer requires block.timestamp >= 30 days.
nohup anvil --port "$PORT" --chain-id "$L1_CHAIN_ID" --accounts 10 --balance 10000 \
  --gas-limit 100000000 --block-base-fee-per-gas 0 --auto-impersonate >"$OUT/anvil.log" 2>&1 &
echo $! >"$OUT/anvil.pid"
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cast chain-id --rpc-url "$RPC" >/dev/null || die "anvil did not start, see $OUT/anvil.log"

forge_script() { # forge_script <script> <sig> [args...]  (runs from l1-contracts, broadcasting as the deployer)
  local script="$1" sig="$2"; shift 2
  (cd "$L1C" && forge script "$script" --rpc-url "$RPC" --private-key "$DEPLOYER_PK" \
    --broadcast --legacy --ffi --slow --sig "$sig" "$@") >>"$OUT/forge.log" 2>&1 ||
    die "forge script $script failed; see $OUT/forge.log"
}
: >"$OUT/forge.log"

# ───────────────────────────── L1 core ─────────────────────────────
log "Deploying L1 core contracts (DeployL1CoreContracts.runForAnvil)"
cat >"$WORK/l1-deployment.toml" <<EOF
owner_address = "$DEPLOYER"
testnet_verifier = true

[deployed_addresses]
create2_factory_addr = "$CREATE2_FACTORY"

[contracts]
governance_security_council_address = "$DEPLOYER"
governance_min_delay = 0
max_number_of_chains = 100

[tokens]
token_weth_address = "0x0000000000000000000000000000000000000000"
EOF
cat >"$WORK/permanent-values.toml" <<EOF
[permanent_contracts]
create2_factory_addr = "0x0000000000000000000000000000000000000000"
create2_factory_salt = "0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5"
EOF
export PERMANENT_VALUES_INPUT="$WORK_REL/permanent-values.toml"
USE_DUMMY_MESSAGE_ROOT=$([[ "${FED_DUMMY_MESSAGE_ROOT:-0}" == "1" ]] && echo true || echo false) \
L1_CONFIG="$WORK_REL/l1-deployment.toml" L1_OUTPUT="$WORK_REL/l1-core-output.toml" \
  forge_script "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol:DeployL1CoreContractsScript" "runForAnvil()"

CORE="$WORK/l1-core-output.toml"
BRIDGEHUB=$($TOMLGET "$CORE" deployed_addresses.bridgehub.bridgehub_proxy_addr)
BRIDGEHUB_ADMIN=$($TOMLGET "$CORE" deployed_addresses.chain_admin)
log "Bridgehub $BRIDGEHUB; accepting its admin from ChainAdminOwnable $BRIDGEHUB_ADMIN (impersonated)"
send --private-key "$DEPLOYER_PK" "$BRIDGEHUB_ADMIN" --value 1ether
send --unlocked --from "$BRIDGEHUB_ADMIN" "$BRIDGEHUB" "acceptAdmin()"

MESSAGE_ROOT=$(call "$BRIDGEHUB" "messageRoot()(address)")
L1_ASSET_ROUTER=$(call "$BRIDGEHUB" "assetRouter()(address)")
L1_NTV=$(call "$L1_ASSET_ROUTER" "nativeTokenVault()(address)")
L1_NULLIFIER=$(call "$L1_ASSET_ROUTER" "L1_NULLIFIER()(address)")
CHAIN_REGISTRATION_SENDER=$(call "$BRIDGEHUB" "chainRegistrationSender()(address)")
CHAIN_ASSET_HANDLER=$(call "$BRIDGEHUB" "chainAssetHandler()(address)")
L1_INTEROP_HANDLER=$($TOMLGET "$CORE" deployed_addresses.bridges.l1_interop_handler_proxy_addr 2>/dev/null || echo "")
GOVERNANCE=$($TOMLGET "$CORE" deployed_addresses.governance_addr)

deploy_artifact() { # deploy_artifact <file.sol> <Contract> [ctor sig] [ctor args...] -> address
  local file="$1" name="$2"; shift 2
  local bytecode args=""
  bytecode=$(jq -r '.bytecode.object' "$L1C/out/$file/$name.json")
  if [[ $# -gt 0 ]]; then args=$(cast abi-encode "$@"); args="${args#0x}"; fi
  cast send --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --create "${bytecode}${args}" --json | jq -r '.contractAddress'
}

# ───────────────────────────── CTM ─────────────────────────────
log "Deploying the ZK token (needed by the CTM config) and the ZiSK Plonk verifier stand-in"
ZK_TOKEN=$(deploy_artifact TestnetERC20Token.sol TestnetERC20Token "constructor(string,string,uint8)" "ZK Token" "ZK" 18)
ZK_TOKEN_ASSET_ID=$(cast keccak "$(cast abi-encode "f(uint256,address,address)" "$L1_CHAIN_ID" 0x0000000000000000000000000000000000010004 "$ZK_TOKEN")")
# The multi-proof CTM needs some code at zisk_plonk_verifier_addr; mock/empty proofs never reach it.
ZISK_STANDIN=$(deploy_artifact EmptyContract.sol EmptyContract)

log "Deploying the CTM (FedDeployCTM = DeployCTM with genesis batch hash from FED_GENESIS_BATCH_HASH='${FED_GENESIS_BATCH_HASH:-<latest.json>}')"
cat >"$WORK/ctm-deployment.toml" <<EOF
owner_address = "$DEPLOYER"
testnet_verifier = true
multi_proof_verifier = true
zk_token_asset_id = "$ZK_TOKEN_ASSET_ID"
zisk_plonk_verifier_addr = "$ZISK_STANDIN"

[contracts]
governance_security_council_address = "0x0000000000000000000000000000000000000000"
governance_min_delay = 0
create2_factory_salt = "0x00000000000000000000000000000000000000000000000000000000000000ff"
create2_factory_addr = "$CREATE2_FACTORY"
validator_timelock_execution_delay = 0
EOF
# forge only resolves project imports and links script libraries for sources inside l1-contracts, so the
# wrapper is copied next to the other generated inputs (script-out is gitignored).
cp "$FED_DIR/script/FedDeployCTM.s.sol" "$WORK/FedDeployCTM.s.sol"
CTM_CONFIG="$WORK_REL/ctm-deployment.toml" CTM_OUTPUT="$WORK_REL/ctm-output.toml" \
  forge_script "script-out/fed-l1/FedDeployCTM.s.sol:FedDeployCTMScript" "runForAnvilTest(address)" "$BRIDGEHUB" \
  --memory-limit 1073741824
CTM_OUT="$WORK/ctm-output.toml"
CTM=$($TOMLGET "$CTM_OUT" deployed_addresses.state_transition.state_transition_proxy_addr)
VALIDIUM_DA_VALIDATOR=$($TOMLGET "$CTM_OUT" deployed_addresses.no_da_validium_l1_validator_addr)

log "Registering CTM $CTM on the Bridgehub (RegisterCTM.runForTest)"
BRIDGEHUB_ADDR="$BRIDGEHUB" CTM_ADDR="$CTM" \
  forge_script "deploy-scripts/ecosystem/RegisterCTM.s.sol:RegisterCTM" "runForTest(address,address)" "$BRIDGEHUB" "$CTM"

VALIDATOR_TIMELOCK=$(call "$CTM" "validatorTimelockPostV29()(address)")
CTM_RELEASE=$(call "$CTM" "currentRelease()(address)")

# ───────────────────────────── test tokens ─────────────────────────────
deploy_token() { # deploy_token <name> <symbol> <holder> -> address (registered in the L1 NTV, holder minted 1000)
  local addr
  addr=$(deploy_artifact TestnetERC20Token.sol TestnetERC20Token "constructor(string,string,uint8)" "$1" "$2" 18)
  send --private-key "$DEPLOYER_PK" "$addr" "mint(address,uint256)" "$3" "$TOKEN_AMOUNT"
  send --private-key "$DEPLOYER_PK" "$L1_NTV" "registerToken(address)" "$addr"
  echo "$addr"
}
log "Deploying USDC (-> Alice $ALICE) and DAI (-> Bob $BOB), 18 decimals, registered in the L1 NTV"
USDC=$(deploy_token "USD Coin (test)" USDC "$ALICE")
DAI=$(deploy_token "Dai (test)" DAI "$BOB")
USDC_ASSET_ID=$(call "$L1_NTV" "assetId(address)(bytes32)" "$USDC")
DAI_ASSET_ID=$(call "$L1_NTV" "assetId(address)(bytes32)" "$DAI")
for a in "$USDC_ASSET_ID" "$DAI_ASSET_ID"; do
  [[ "$(cast to-uint256 "$a")" != "0" ]] || die "token not registered in the NTV"
done
ETH_ASSET_ID=$(call "$L1_NTV" "BASE_TOKEN_ASSET_ID()(bytes32)")

# ───────────────────────────── chains ─────────────────────────────
for CID in "${CHAINS[@]}"; do
  op_var="OPERATOR_$CID"; OP="${!op_var}"
  log "Registering chain $CID (RegisterZKChain.runForTest), operator $OP"
  cat >"$WORK/chain-$CID.toml" <<EOF
owner_address = "$DEPLOYER"

[chain]
chain_chain_id = $CID
base_token_addr = "$ETH_TOKEN_ADDRESS"
bridgehub_create_new_chain_salt = $((CID * 1000000))
validium_mode = false
base_token_gas_price_multiplier_nominator = 1
base_token_gas_price_multiplier_denominator = 1
governance_security_council_address = "0x0000000000000000000000000000000000000000"
governance_min_delay = 0
validator_sender_operator_eth = "$OP"
validator_sender_operator_blobs_eth = "$OP"
EOF
  CTM_OUTPUT="$WORK_REL/ctm-output.toml" ZK_CHAIN_CONFIG="$WORK_REL/chain-$CID.toml" \
    ZK_CHAIN_OUT="$WORK_REL/chain-$CID-output.toml" \
    forge_script "deploy-scripts/ctm/RegisterZKChain.s.sol:RegisterZKChainScript" "runForTest(address,uint256)" "$CTM" "$CID"
  DP=$(call "$BRIDGEHUB" "getZKChain(uint256)(address)" "$CID")
  [[ "$DP" != "0x0000000000000000000000000000000000000000" ]] || die "chain $CID not registered"
  [[ "$(call "$DP" "getAdmin()(address)")" == "$DEPLOYER" ]] || die "chain $CID admin is not the deployer"

  log "Chain $CID ($DP): unpause deposits, Validium/EMPTY_NO_DA DA pair, enableInterop, interop pool"
  send --private-key "$DEPLOYER_PK" "$DP" "unpauseDeposits()"
  send --private-key "$DEPLOYER_PK" "$DP" "setDAValidatorPair(address,uint8)" "$VALIDIUM_DA_VALIDATOR" "$L2_DA_COMMITMENT_SCHEME_EMPTY_NO_DA"
  # protocol-docs/interop-gating.md#order-per-chain. Steps 1-3 (upgrade, legacy pairs, backfill) do not
  # apply: a chain created on this release is never backfill-pending. Step 4 (second proof system) is
  # waived: governance enables with requireSecondProofSystem = false.
  [[ "$(call "$L1_NTV" "chainBalanceBackfillPending(uint256)(bool)" "$CID")" == "false" ]] || die "chain $CID backfill pending"
  send --private-key "$DEPLOYER_PK" "$MESSAGE_ROOT" "enableInterop(uint256,bool)" "$CID" false
  # Step 6: move the (zero) pre-enable balances of every asset the chain may hold into the pool.
  for A in "$ETH_ASSET_ID" "$USDC_ASSET_ID" "$DAI_ASSET_ID"; do
    send --private-key "$DEPLOYER_PK" "$L1_NTV" "moveChainBalanceToInteropPool(uint256,bytes32)" "$CID" "$A"
  done
done

# Step 7: each admin allows the other chain. Enqueues one L2 service tx (priority op) per direction.
for CID in "${CHAINS[@]}"; do
  for PEER in "${CHAINS[@]}"; do
    [[ "$CID" == "$PEER" ]] && continue
    log "allowInteropPeer($CID, $PEER)"
    send --private-key "$DEPLOYER_PK" "$CHAIN_REGISTRATION_SENDER" "allowInteropPeer(uint256,uint256)" "$CID" "$PEER"
    [[ "$(call "$CHAIN_REGISTRATION_SENDER" "interopPeerAllowed(uint256,uint256)(bool)" "$CID" "$PEER")" == "true" ]] ||
      die "peer $PEER not allowed on $CID"
  done
done

# ───────────────────────────── addresses.json ─────────────────────────────
log "Writing $OUT/addresses.json"
python3 "$FED_DIR/scripts/collect.py" \
  --rpc "$RPC" --l1-chain-id "$L1_CHAIN_ID" --out "$OUT/addresses.json" --work "$WORK" \
  --set bridgehub="$BRIDGEHUB" message_root="$MESSAGE_ROOT" l1_asset_router="$L1_ASSET_ROUTER" \
        l1_native_token_vault="$L1_NTV" l1_nullifier="$L1_NULLIFIER" l1_interop_handler="$L1_INTEROP_HANDLER" \
        chain_registration_sender="$CHAIN_REGISTRATION_SENDER" chain_asset_handler="$CHAIN_ASSET_HANDLER" \
        governance="$GOVERNANCE" bridgehub_admin="$BRIDGEHUB_ADMIN" \
        chain_type_manager="$CTM" ctm_release="$CTM_RELEASE" validator_timelock="$VALIDATOR_TIMELOCK" \
        validium_l1_da_validator="$VALIDIUM_DA_VALIDATOR" zk_token="$ZK_TOKEN" zk_token_asset_id="$ZK_TOKEN_ASSET_ID" \
        eth_asset_id="$ETH_ASSET_ID" usdc="$USDC" usdc_asset_id="$USDC_ASSET_ID" dai="$DAI" dai_asset_id="$DAI_ASSET_ID" \
        deployer="$DEPLOYER" deployer_private_key="$DEPLOYER_PK" \
        alice="$ALICE" alice_private_key="$ALICE_PK" bob="$BOB" bob_private_key="$BOB_PK" \
  --chain 301 "$OPERATOR_301" "$OPERATOR_PK_301" \
  --chain 302 "$OPERATOR_302" "$OPERATOR_PK_302"
cp "$WORK"/*.toml "$OUT/" 2>/dev/null || true

# Dump the post-deploy state (reload with fed-l1/start.sh). Taken before the smoke test, which reverts anyway.
cast rpc --rpc-url "$RPC" anvil_dumpState | python3 -c '
import sys, json, gzip
h = json.load(sys.stdin)
open(sys.argv[1], "wb").write(gzip.decompress(bytes.fromhex(h[2:])))' "$OUT/state.json"

# ───────────────────────────── smoke test ─────────────────────────────
if [[ "${FED_SKIP_SMOKE:-0}" != "1" ]]; then
  log "Smoke test: settle batch 1 on both chains inside an evm snapshot, then revert"
  SNAP=$(cast rpc --rpc-url "$RPC" evm_snapshot | tr -d '"')
  python3 "$FED_DIR/scripts/settle_empty_batch.py" --rpc "$RPC" --addresses "$OUT/addresses.json" --chain 301 --chain 302 \
    || { cast rpc --rpc-url "$RPC" evm_revert "$SNAP" >/dev/null; die "smoke settlement failed"; }
  log "Smoke test: Alice deposits 100 USDC to 301, Bob 100 DAI to 302 via L1AssetRouter.depositViaInterop"
  smoke_deposit() { # <pk> <holder> <token> <assetId> <chain>
    send --private-key "$1" "$3" "approve(address,uint256)" "$L1_NTV" 100000000000000000000
    # lowNullifierIndex 0: L1's commitment IMT holds only its zero leaf plus earlier legs with larger
    # values; a host must pass the real predecessor index (see README).
    send --private-key "$1" "$L1_ASSET_ROUTER" "depositViaInterop(uint256,bytes32,bytes,uint256)" "$5" "$4" \
      "$(cast abi-encode "f(uint256,address,address)" 100000000000000000000 "$2" "$3")" 0
  }
  smoke_deposit "$ALICE_PK" "$ALICE" "$USDC" "$USDC_ASSET_ID" 301 && smoke_deposit "$BOB_PK" "$BOB" "$DAI" "$DAI_ASSET_ID" 302 \
    || { cast rpc --rpc-url "$RPC" evm_revert "$SNAP" >/dev/null; die "smoke deposit failed"; }
  echo "  deposits ok; L1 batch number of the L1 commitment tree: $(call "$MESSAGE_ROOT" "currentChainBatchNumber(uint256)(uint256)" "$L1_CHAIN_ID")"
  cast rpc --rpc-url "$RPC" evm_revert "$SNAP" >/dev/null
fi

# ───────────────────────────── verification ─────────────────────────────
log "Verification"
for CID in "${CHAINS[@]}"; do
  DP=$(call "$BRIDGEHUB" "getZKChain(uint256)(address)" "$CID")
  echo "chain $CID: Bridgehub.getZKChain = $DP, CTM = $(call "$BRIDGEHUB" "chainTypeManager(uint256)(address)" "$CID")"
  echo "  getTotalBatchesCommitted = $(call "$DP" "getTotalBatchesCommitted()(uint256)")"
  echo "  isInteropEnabled = $(call "$MESSAGE_ROOT" "isInteropEnabled(uint256)(bool)" "$CID")"
done
jq '.chains | map_values(.genesis_stored_batch_info)' "$OUT/addresses.json"

if [[ "${FED_KEEP_ANVIL:-1}" == "1" ]]; then
  log "Done. anvil keeps running on $RPC (pid $(cat "$OUT/anvil.pid")); addresses in $OUT/addresses.json"
else
  kill "$(cat "$OUT/anvil.pid")"
  log "Done. anvil stopped; reload with fed-l1/start.sh"
fi
