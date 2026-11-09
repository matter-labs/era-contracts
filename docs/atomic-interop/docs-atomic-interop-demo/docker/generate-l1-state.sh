#!/usr/bin/env bash
# Builds docker/l1-state.json.gz: an L1 (Anvil) state with two ZKsync OS v33.2 chains, 506 and 507, that
# settle directly on L1. For maintainers only; the sandbox downloads the published result (see
# fetch-l1-state.mjs), and uses this file instead when present.
#
# Input: a v33.2 single-chain L1 state (chain 506, era-contracts v0.33.2), public in
# matter-labs/local-prividium at dev/zksyncos/l1-state.json.gz (commit f5fcd53). The script adds
# chain 507 by replaying, against that state, the L1 transactions that created chain 506
# (RegisterZKChain.s.sol plus the deployment's funding), with a new chain ID, new operator keys and
# a new CREATE2 salt:
#
#   fund the three operators, deploy the chain's Governance, ChainAdminOwnable and ProxyAdmin,
#   Bridgehub.createNewChain, four ValidatorTimelock.addValidatorRoles, setTokenMultiplier,
#   setPendingAdmin, acceptAdmin + unpauseDeposits + setDAValidatorPair through the chain admin,
#   and 10 deposits that fund the dev wallets on L2.
#
# Chain registration for interop (ChainRegistrationSender.registerChain) can't be part of this state:
# it needs an executed batch of each chain on L1. The sandbox's `register` service does it at start.
#
# Usage: generate-l1-state.sh <l1-state.json or l1-state.json.gz of the v33.2 fixture>
# Needs: docker, cast, jq, gzip.
set -euo pipefail

INPUT=${1:?usage: $0 <v33.2 l1-state.json[.gz]>}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/l1-state.json.gz
WORK=$(mktemp -d)
ANVIL_IMAGE=ghcr.io/foundry-rs/foundry:v1.8.4 # the version that dumped the input state
PORT=18545
RPC=http://127.0.0.1:$PORT
CONTAINER=atomic-sandbox-gen-l1
INPUT_SHA256=34c650d6dd5a4666925eac7b1a45035657d4c8a40688599149b38d4847f8a83c

# --- Inputs ---------------------------------------------------------------------------------------
if [[ $INPUT == *.gz ]]; then gzip -dc "$INPUT" > "$WORK/in.json"; else cp "$INPUT" "$WORK/in.json"; fi
actual=$(shasum -a 256 "$WORK/in.json" | cut -d' ' -f1)
[[ $actual == "$INPUT_SHA256" ]] || { echo "unexpected input state: sha256 $actual" >&2; exit 1; }

# L1 ecosystem contracts and accounts of the fixture (era-contracts v0.33.2).
BRIDGEHUB=0x24420e672f8711a040e8ab27ac33026d277a7e2d
ECOSYSTEM_ADMIN=0xb78aed4d010f9e026b4406a68c095c52d80087ea # ChainAdminOwnable that owns the Bridgehub
VALIDATOR_TIMELOCK=0x2a2f8f8136900d58a61b9247f8a5c32cbc0d41b1
CREATE2_FACTORY=0x4e59b44847b379578588920ca78fbf26c0b4956c
L1_DA_VALIDATOR=0xbe8a822490e6062c592bebd938598fa151092bb7 # used by chain 506
DEPLOYER_SK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # Anvil #0
OWNER_SK=0x17c15e218e597be033bed93a4b051dfe42400a06cc568216125085b667fbed40    # chain owner of 506, reused
CHAIN_ID=507

# Operator keys for chain 507 (test keys; each server needs its own L1 accounts).
COMMIT_SK=$(cast keccak "atomic-interop-sandbox/507/commit")
PROVE_SK=$(cast keccak "atomic-interop-sandbox/507/prove")
EXECUTE_SK=$(cast keccak "atomic-interop-sandbox/507/execute")
COMMIT=$(cast wallet address "$COMMIT_SK")
PROVE=$(cast wallet address "$PROVE_SK")
EXECUTE=$(cast wallet address "$EXECUTE_SK")

# Calldata of chain 506's creation transactions, taken from the input state.
tx_data() { jq -r --argjson i "$1" '.transactions[$i].info.traces[0].trace.data' "$WORK/in.json"; }
tx_to() { jq -r --argjson i "$1" '.transactions[$i].info.to' "$WORK/in.json"; }
# The chain-506 deployments through the CREATE2 factory share one salt; find them by the
# createNewChain transaction that follows them.
CREATE_IDX=$(jq -r --arg a "$ECOSYSTEM_ADMIN" '[.transactions | to_entries[] | select(.value.info.to == $a and (.value.info.traces[0].trace.data | contains("f113c88b")))][0].key' "$WORK/in.json")
GOV_IDX=$((CREATE_IDX - 3)) ADMIN_IDX=$((CREATE_IDX - 2)) PROXY_ADMIN_IDX=$((CREATE_IDX - 1))
for i in $GOV_IDX $ADMIN_IDX $PROXY_ADMIN_IDX; do
  [[ $(tx_to "$i") == "$CREATE2_FACTORY" ]] || { echo "tx $i is not a CREATE2 deployment" >&2; exit 1; }
done
OLD_SALT=$(tx_data "$GOV_IDX" | cut -c3-66)
OLD_CHAIN_ADMIN=$(jq -r --argjson i "$ADMIN_IDX" '.transactions[$i].info.traces[1].trace.address' "$WORK/in.json")
SALT=$(cast keccak "atomic-interop-sandbox/507/create2" | cut -c3-)

# --- Start Anvil on the input state ---------------------------------------------------------------
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --user root -p "127.0.0.1:$PORT:8545" -v "$WORK:/work" \
  --entrypoint anvil "$ANVIL_IMAGE" --host 0.0.0.0 --port 8545 \
  --load-state /work/in.json --dump-state /work/out.json --preserve-historical-states > /dev/null
trap 'docker rm -f "$CONTAINER" > /dev/null 2>&1 || true' EXIT
for _ in $(seq 1 100); do cast chain-id --rpc-url "$RPC" > /dev/null 2>&1 && break; sleep 0.3; done

# Same transaction type and gas price as the fixture, so the deposits' base cost matches.
send() { cast send --rpc-url "$RPC" --legacy --gas-price 1gwei "$@" > /dev/null; }

# --- Replay chain creation for 507 ----------------------------------------------------------------
for operator in "$COMMIT" "$PROVE" "$EXECUTE"; do
  send --private-key "$DEPLOYER_SK" "$operator" --value 100ether
done

# Governance(owner, 0, 0), ChainAdminOwnable(owner, 0), ProxyAdmin factory(chain admin).
deploy() { # $1 = init code without 0x; prints the new address
  local addr
  addr=$(cast call --rpc-url "$RPC" "$CREATE2_FACTORY" "0x$SALT$1")
  send --private-key "$DEPLOYER_SK" "$CREATE2_FACTORY" "0x$SALT$1"
  echo "0x${addr: -40}"
}
GOV_INIT=$(tx_data "$GOV_IDX" | cut -c67-)
ADMIN_INIT=$(tx_data "$ADMIN_IDX" | cut -c67-)
GOVERNANCE=$(deploy "$GOV_INIT")
CHAIN_ADMIN=$(deploy "$ADMIN_INIT")
old_admin_word=$(printf '%064s' "${OLD_CHAIN_ADMIN#0x}" | tr ' ' 0)
new_admin_word=$(printf '%064s' "$(echo "${CHAIN_ADMIN#0x}" | tr 'A-F' 'a-f')" | tr ' ' 0)
PROXY_INIT=$(tx_data "$PROXY_ADMIN_IDX" | cut -c67- | sed "s/$old_admin_word/$new_admin_word/")
deploy "$PROXY_INIT" > /dev/null
[[ $OLD_SALT != "$SALT" ]]

# Bridgehub.createNewChain through the ecosystem admin: chain 506's call with the first argument
# (the chain ID) set to 507. Everything else, including the force-deployments data, is unchanged.
CREATE_DATA=$(tx_data "$CREATE_IDX")
prefix=${CREATE_DATA%%f113c88b*}
pos=$((${#prefix} + 8))
old_id=$(printf '%064x' 506)
[[ ${CREATE_DATA:$pos:64} == "$old_id" ]] || { echo "unexpected createNewChain layout" >&2; exit 1; }
CREATE_DATA="${CREATE_DATA:0:$pos}$(printf '%064x' "$CHAIN_ID")${CREATE_DATA:$((pos + 64))}"
send --private-key "$DEPLOYER_SK" "$ECOSYSTEM_ADMIN" "$CREATE_DATA"
DIAMOND=$(cast call --rpc-url "$RPC" "$BRIDGEHUB" "getZKChain(uint256)(address)" "$CHAIN_ID")
[[ $DIAMOND != 0x0000000000000000000000000000000000000000 ]]

# Validator roles: (precommitter, committer, reverter, prover, executor, upgrader).
roles="addValidatorRoles(address,address,(bool,bool,bool,bool,bool,bool))"
send --private-key "$DEPLOYER_SK" "$VALIDATOR_TIMELOCK" "$roles" "$DIAMOND" "$PROVE" "(true,false,true,false,false,true)"
send --private-key "$DEPLOYER_SK" "$VALIDATOR_TIMELOCK" "$roles" "$DIAMOND" "$COMMIT" "(false,true,false,false,false,false)"
send --private-key "$DEPLOYER_SK" "$VALIDATOR_TIMELOCK" "$roles" "$DIAMOND" "$PROVE" "(false,false,false,true,false,false)"
send --private-key "$DEPLOYER_SK" "$VALIDATOR_TIMELOCK" "$roles" "$DIAMOND" "$EXECUTE" "(false,false,false,false,true,false)"

send --private-key "$DEPLOYER_SK" "$DIAMOND" "setTokenMultiplier(uint128,uint128)" 1 1
send --private-key "$DEPLOYER_SK" "$DIAMOND" "setPendingAdmin(address)" "$CHAIN_ADMIN"

admin_call() { # $1 = calldata on the diamond, sent by the chain owner through the chain admin
  send --private-key "$OWNER_SK" "$CHAIN_ADMIN" "multicall((address,uint256,bytes)[],bool)" "[($DIAMOND,0,$1)]" true
}
admin_call "$(cast calldata "acceptAdmin()")"
admin_call "$(cast calldata "unpauseDeposits()")"
admin_call "$(cast calldata "setDAValidatorPair(address,uint8)" "$L1_DA_VALIDATOR" 4)"

# Fund the same 10 L2 dev wallets as on chain 506: 100 ETH each.
for wallet in \
  0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 \
  0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc \
  0x976EA74026E726554dB657fA54763abd0C3a0aa9 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955 \
  0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720; do
  send --private-key "$DEPLOYER_SK" "$BRIDGEHUB" \
    "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))" \
    "($CHAIN_ID,100000131250000000000,$wallet,100000000000000000000,0x,500000,800,[],$wallet)" \
    --value 100000131250000000000
done

# --- Checks ---------------------------------------------------------------------------------------
check() { [[ ${2%% *} == "${3%% *}" ]] || { echo "check failed: $1: got $2, want $3" >&2; exit 1; }; }
lower() { echo "$1" | tr 'A-F' 'a-f'; }
check "admin of 507" "$(lower "$(cast call --rpc-url "$RPC" "$DIAMOND" "getAdmin()(address)")")" "$(lower "$CHAIN_ADMIN")"
DIAMOND_506=$(cast call --rpc-url "$RPC" "$BRIDGEHUB" "getZKChain(uint256)(address)" 506)
check "priority txs on 507 (deposits)" "$(cast call --rpc-url "$RPC" "$DIAMOND" "getTotalPriorityTxs()(uint256)")" \
  "$(cast call --rpc-url "$RPC" "$DIAMOND_506" "getTotalPriorityTxs()(uint256)")"
check "protocol version of 507" "$(cast call --rpc-url "$RPC" "$DIAMOND" "getProtocolVersion()(uint256)")" \
  "$(cast call --rpc-url "$RPC" "$DIAMOND_506" "getProtocolVersion()(uint256)")"
check "deposits paused on 507" "$(cast call --rpc-url "$RPC" "$DIAMOND" "depositsPaused()(bool)")" false
check "settlement layer of 507" "$(cast call --rpc-url "$RPC" "$BRIDGEHUB" "settlementLayer(uint256)(uint256)" "$CHAIN_ID")" 31337
check "settlement layer of 506" "$(cast call --rpc-url "$RPC" "$BRIDGEHUB" "settlementLayer(uint256)(uint256)" 506)" 31337

# --- Dump -----------------------------------------------------------------------------------------
docker stop -t 60 "$CONTAINER" > /dev/null # Anvil writes --dump-state on shutdown
[[ -s $WORK/out.json ]] || { echo "Anvil wrote no state" >&2; exit 1; }
jq -e '(.historical_states | length) == (.transactions | length)' "$WORK/out.json" > /dev/null
gzip -9 -c "$WORK/out.json" > "$OUT"

cat << EOF
Wrote $OUT ($(du -h "$OUT" | cut -f1))
  L1 transactions: $(jq '.transactions | length' "$WORK/out.json"), blocks: $(jq '.blocks | length' "$WORK/out.json")
  chain 507: diamond $DIAMOND, chain admin $CHAIN_ADMIN, governance $GOVERNANCE
  chain 507 operators: commit $COMMIT, prove $PROVE, execute $EXECUTE
EOF
rm -rf "$WORK"
