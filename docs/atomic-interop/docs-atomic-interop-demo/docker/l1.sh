#!/usr/bin/env bash
# Runs the sandbox L1: Anvil, loaded from l1-state.json.gz, inside the foundry image.
#   l1.sh            start Anvil on port 8545
#   l1.sh healthy    exit 0 once Anvil answers and its clock is synced
set -euo pipefail

STATE=/tmp/l1-state.json
SYNCED=/tmp/l1-clock-synced

if [[ ${1:-} == healthy ]]; then
  [[ -f $SYNCED ]] && cast chain-id --rpc-url http://127.0.0.1:8545 > /dev/null
  exit
fi

rm -f "$SYNCED"
gzip -dc /sandbox/l1-state.json.gz > "$STATE"

# Anvil resumes its clock from the state's last block, while the chains stamp their blocks with the
# current time. Batches more than an hour ahead of L1 can't be committed, so move the clock to now.
(
  until cast block-number --rpc-url http://127.0.0.1:8545 > /dev/null 2>&1; do sleep 0.2; done
  cast rpc --rpc-url http://127.0.0.1:8545 evm_setTime "$(date +%s)" > /dev/null
  touch "$SYNCED"
) &

exec anvil --host 0.0.0.0 --port 8545 --load-state "$STATE" --preserve-historical-states \
  --block-time 0.25 --mixed-mining --slots-in-an-epoch 10
