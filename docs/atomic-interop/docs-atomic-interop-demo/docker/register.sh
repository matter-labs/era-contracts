#!/usr/bin/env bash
# Registers chains 506 and 507 with each other for interop, then marks the sandbox ready.
#   register.sh          run once, then keep the container up
#   register.sh ready    exit 0 once registration is done (the healthcheck)
#
# ChainRegistrationSender.registerChain(chainToBeRegistered, chainRegisteredOn) reverts until
# chainToBeRegistered has an executed batch on L1, so this can't be part of the saved L1 state.
set -euo pipefail

READY=/tmp/sandbox-ready
[[ ${1:-} == ready ]] && exec test -f "$READY"

L1=http://l1:8545
declare -A RPC=([506]=http://chain-a:3050 [507]=http://chain-b:3050)
BRIDGEHUB=0x24420e672f8711a040e8ab27ac33026d277a7e2d
L2_BRIDGEHUB=0x0000000000000000000000000000000000010002
SENDER_SK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # Anvil #0, funded on L1
log() { echo "[register] $*"; }
num() { echo "${1%% *}"; } # cast prints "1 [1e0]"

REGISTRATION_SENDER=$(cast call --rpc-url $L1 $BRIDGEHUB "chainRegistrationSender()(address)")

for chain in 506 507; do
  diamond=$(cast call --rpc-url $L1 $BRIDGEHUB "getZKChain(uint256)(address)" $chain)
  until (($(num "$(cast call --rpc-url $L1 "$diamond" "getTotalBatchesExecuted()(uint256)")") > 0)); do sleep 0.5; done
  log "chain $chain has a batch executed on L1"
done

for pair in "506 507" "507 506"; do
  read -r chain on <<< "$pair"
  if [[ $(cast call --rpc-url $L1 "$REGISTRATION_SENDER" "chainRegisteredOnChain(uint256,uint256)(bool)" "$chain" "$on") == false ]]; then
    # cast's receipt poller can log a harmless error after the receipt arrives; show output on failure.
    if ! out=$(cast send --rpc-url $L1 --private-key $SENDER_SK "$REGISTRATION_SENDER" "registerChain(uint256,uint256)" "$chain" "$on" 2>&1); then
      echo "$out" >&2
      exit 1
    fi
  fi
  # The registration reaches the other chain as an L1 -> L2 service transaction, which sets the
  # registered chain's base token asset ID in that chain's L2 Bridgehub.
  until asset=$(cast call --rpc-url "${RPC[$on]}" $L2_BRIDGEHUB "baseTokenAssetId(uint256)(bytes32)" "$chain" 2> /dev/null) &&
    [[ $asset =~ ^0x[0-9a-f]{64}$ && $asset != 0x0000000000000000000000000000000000000000000000000000000000000000 ]]; do
    sleep 0.5
  done
  log "chain $chain registered on chain $on"
done

touch "$READY"
log "sandbox ready: L1 http://127.0.0.1:8545, chain 506 http://127.0.0.1:3050, chain 507 http://127.0.0.1:3051"
exec sleep infinity
