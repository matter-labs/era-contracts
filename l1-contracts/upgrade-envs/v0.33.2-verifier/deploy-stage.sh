#!/usr/bin/env bash
# Broadcast the v0.33.2 CREATE2 deployments (`[deploy_calls]` of output/stage/ecosystem.toml) to Sepolia.
# Any funded EOA can send them: the addresses depend only on the salt and the init code. Idempotent: a
# contract whose address already has code is skipped. Each sent tx hash is appended to
# output/stage/transactions.txt.
#
# Usage: L1_RPC=<sepolia rpc> DEPLOYER_PK_FILE=<file holding the key> ./deploy-stage.sh
set -euo pipefail

: "${L1_RPC:?set L1_RPC to a Sepolia RPC}"
: "${DEPLOYER_PK_FILE:?set DEPLOYER_PK_FILE to a file holding the deployer key}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$HERE/output/stage/ecosystem.toml
LOG=$HERE/output/stage/transactions.txt
PK=$(tr -d '[:space:]' < "$DEPLOYER_PK_FILE")

python3 -c "
import json, subprocess, sys, tomllib
d = tomllib.load(open('$OUT', 'rb'))
st, dep = d['state_transition'], d['deployed_addresses']
addresses = [st['verifier_plonk_addr'], st['verifier_addr'], dep['upgrade_stage_validator'], dep['l1_governance_upgrade_timer']]
j = json.loads(subprocess.check_output(['cast', 'abi-decode', '--json', '--input', 'f((address,uint256,bytes)[])', d['deploy_calls']['calls']]))
calls = (j['data'] if isinstance(j, dict) else j)[0]
assert len(calls) == len(addresses) == len(d['deploy_calls']['contracts'])
for name, addr, (target, value, data) in zip(d['deploy_calls']['contracts'], addresses, calls):
    print(name, addr, target, data)
" | while read -r NAME ADDR TARGET DATA; do
  if [ "$(cast codesize "$ADDR" --rpc-url "$L1_RPC")" != "0" ]; then
    echo "$NAME already at $ADDR, skipping"
    continue
  fi
  TX=$(cast send "$TARGET" "$DATA" --private-key "$PK" --rpc-url "$L1_RPC" --json | python3 -c "
import json, sys
r = json.load(sys.stdin)
assert r['status'] == '0x1', r
print(r['transactionHash'])")
  [ "$(cast codesize "$ADDR" --rpc-url "$L1_RPC")" != "0" ] || { echo "no code at $ADDR after $TX"; exit 1; }
  echo "$NAME $ADDR $TX" | tee -a "$LOG"
done
