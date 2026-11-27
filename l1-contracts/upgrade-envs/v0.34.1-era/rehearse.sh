#!/usr/bin/env bash
# Rehearse the v0.34.1 Era verifier patch of one environment on an L1 fork and check the L1 state it leaves. The
# environment is UPGRADE_ENV (stage, testnet3). Expected values come from $UPGRADE_ENV.toml, permanent-values, the
# genesis, AllContractsHashes.json and the chain, never from the output being checked.
#   1. prepare (standalone only): CTMUpgrade_v34_1Era.prepare as a dry run from DEPLOYER, then its deployer
#      transactions sent impersonated; forge builds into FOUNDRY_OUT (default: a temp dir), never out/. Writes
#      output/$UPGRADE_ENV/ecosystem.toml
#   2. CREATE2 provenance of the four deployer transactions
#   3. deployed code and keys; the Airbender fixture proof against the new and the old Airbender verifier
#   4. the output decoded, only what step 5 can't show: the cut, the exact governance calls, the test calls'
#      arguments, the keys people read; and each chain's calls, built as protocol_ops' chain commands build them
#   5. on the fork, as the real senders (impersonated): what must revert before governance, stages 0/1/2 with an
#      unpause by anyone between 0 and 1, the CTM after them, each chain's timestamp, its upgrade through the
#      ValidatorTimelock and, from the same state, through its ChainAdmin, and a test chain
#
# Usage:
#   UPGRADE_ENV=<env> DEPLOYER=<eoa> L1_FORK_URL=<rpc> [FORK_BLOCK=<n>] [PORT=<p>] ./rehearse.sh
#       Starts its own anvil fork (stopped by PID on exit) and prepares on it. Needs the Linux CI build in
#       {system,l1,l2}-contracts/zkout, l1-contracts/out and da-contracts/out (macOS zksolc hashes differ).
#   UPGRADE_ENV=<env> L1_RPC_URL=<fork> ECOSYSTEM_TOML=<bundle's toml> ./rehearse.sh
#       protocol_ops' verify_fork: a fork the bundle was replayed on. No anvil, no prepare, no build; the deployer
#       transactions come from prepare/ next to ECOSYSTEM_TOML.
#   UPGRADE_ENV=<env> L1_RPC_URL=<chain> [ECOSYSTEM_TOML=<toml>] ./rehearse.sh --published-only
#       Read-only, safe against the real chain: steps 2 (if prepare/ is there) and 3. Without ECOSYSTEM_TOML it reads
#       the committed output.
# Needs foundry (cast; anvil and forge standalone) and python3 >= 3.11 (tomllib). Sends only to an Anvil fork.
set -Eeuo pipefail

PUBLISHED_ONLY=0
[ "${1:-}" = "--published-only" ] && PUBLISHED_ONLY=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(cd "$HERE/../.." && pwd)
S=$(mktemp -d)
PORT=${PORT:-8641}
FAILED=0
SKIPPED=0
DONE=0
ERR_AT=
ANVIL_PID=
BROADCAST_LOG=

die() { echo "REHEARSAL FAILED: $*"; DONE=1; exit 1; }
on_exit() {
  local rc=$?
  [ -z "$ANVIL_PID" ] || kill "$ANVIL_PID" 2>/dev/null || true
  [ "$DONE" = "1" ] || [ "$rc" = "0" ] || echo "REHEARSAL FAILED: stopped on an unexpected error (exit $rc) at ${ERR_AT:-unknown}"
}
trap on_exit EXIT
trap 'ERR_AT="line $LINENO: $BASH_COMMAND"' ERR

# cast >= 1.8 wraps --json output in {"schema_version", "success", "data", "errors"}; older casts print the value
# itself. unwrap.py [IN [OUT]] prints (or writes to OUT) the bare value and fails with cast's errors.
cat > "$S/unwrap.py" <<'PYUNWRAP'
import json, sys
v = json.load(open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin)
if isinstance(v, dict) and "schema_version" in v:
    if not v.get("success"):
        sys.exit("; ".join(e.get("message", "") for e in v.get("errors") or [])[:300] or "cast failed")
    v = v.get("data")
if len(sys.argv) > 2:
    json.dump(v, open(sys.argv[2], "w"))
else:
    print(v if isinstance(v, str) else json.dumps(v))
PYUNWRAP

fail() { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
skip() { echo "  SKIP $*"; SKIPPED=$((SKIPPED + 1)); }
lc() { tr 'A-F' 'a-f' <<< "$1"; }
# chk LABEL GOT EXPECTED — an empty EXPECTED is a failed read, never a match.
chk() {
  if [ -z "$3" ]; then fail "$1: no expected value (failed read), got ${2:-nothing}"
  elif [ "$(lc "$2")" = "$(lc "$3")" ]; then echo "  OK   $1"
  else fail "$1: expected $3, got ${2:-nothing}"; fi
}
# differs LABEL A B — both read, and different.
differs() {
  if [ -z "$2" ] || [ -z "$3" ]; then fail "$1: failed read ('$2' / '$3')"
  elif [ "$(lc "$2")" != "$(lc "$3")" ]; then echo "  OK   $1"
  else fail "$1: both are $2"; fi
}
call() { cast call "$@" --rpc-url "$RPC"; }
first() { awk '{print $1}'; }
# send FROM TO DATA LABEL — impersonated; cast waits for the receipt, kept in $S/receipt.json (empty if none).
send() {
  local status
  : > "$S/receipt.json"
  { cast send --unlocked --from "$1" "$2" "$3" --rpc-url "$RPC" --json 2> "$S/send.err" | grep '^{' | tail -1 > "$S/send.json"; } || true
  python3 "$S/unwrap.py" "$S/send.json" "$S/receipt.json" 2>> "$S/send.err" || true
  status=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status"))' "$S/receipt.json" 2> /dev/null) || status=
  if [ "$status" = "0x1" ]; then echo "  OK   $4"; else fail "$4 (status ${status:-none}: $(head -c 300 "$S/send.err"))"; fi
}

: "${UPGRADE_ENV:?set UPGRADE_ENV to the environment (stage, testnet3)}"
[ -f "$HERE/$UPGRADE_ENV.toml" ] || die "no $HERE/$UPGRADE_ENV.toml"
python3 -c 'import tomllib' 2>/dev/null || die "needs python3 >= 3.11 (tomllib)"
if [ "$PUBLISHED_ONLY" = "1" ]; then
  [ -n "${L1_RPC_URL:-}" ] || die "--published-only needs L1_RPC_URL"
elif [ -n "${L1_RPC_URL:-}" ]; then
  # Only the script's own anvil prepares: the prepare would broadcast to L1_RPC_URL.
  [ -n "${ECOSYSTEM_TOML:-}" ] || die "L1_RPC_URL needs ECOSYSTEM_TOML or --published-only; unset it to rehearse on this script's own anvil"
else
  : "${L1_FORK_URL:?set L1_FORK_URL to an RPC of the environment L1}"
  # The prepare runs as this account and the bundle is built for it: it must be the one that will broadcast.
  : "${DEPLOYER:?set DEPLOYER to the deployer EOA}"
fi
OUT_REL=/upgrade-envs/v0.34.1-era/output/$UPGRADE_ENV/ecosystem.toml
OUT=${ECOSYSTEM_TOML:-$WT$OUT_REL}
export OUT S HERE WT UPGRADE_ENV

# ---------------------------------------------------------------- inputs
python3 - "$HERE/$UPGRADE_ENV.toml" "$WT/upgrade-envs/permanent-values/$UPGRADE_ENV.toml" \
  "$WT/../configs/genesis/era/latest.json" "$WT/../AllContractsHashes.json" <<'PYINPUTS' > "$S/inputs.env" \
  || die "cannot read the inputs"
import json, re, sys, tomllib
env, permanent = (tomllib.load(open(p, "rb")) for p in sys.argv[1:3])
genesis, hashes = (json.load(open(p)) for p in sys.argv[3:5])
ctm = permanent["ctm_contracts"]["ctms"][0]  # the script's: the first CTM, which must be Era
if ctm["is_zk_sync_os"]:
    sys.exit("  permanent values: the first CTM is not Era")
old, new = env["old_protocol_version"], env["new_protocol_version"]
if not (isinstance(old, int) and isinstance(new, int) and old >> 32 == new >> 32 and new == old + 1):
    sys.exit(f"  {old} -> {new} is not the next patch of the same minor")
evm = {e["contractName"]: e for e in hashes}
verifier_name = "EraMultiProofTestnetVerifier" if env["testnet_verifier"] is True else "EraMultiProofVerifier"
ADDRESS, NUMBER, WORD, BOOL = r"0x[0-9a-fA-F]{40}", r"[0-9]+", r"0x[0-9a-fA-F]{64}", r"True|False"
facts = [
    ("CTM", ctm["proxy"], ADDRESS),
    ("TESTNET", env["testnet_verifier"], BOOL),
    ("OLD", old, NUMBER),
    ("NEW", new, NUMBER),
    ("SALT", env["create2_factory_salt"], WORD),
    ("CHAIN_IDS", " ".join(str(c) for c in env["chain_ids"]), r"[0-9]+( [0-9]+)*"),
    ("L1_CHAIN_ID", permanent["l1_chain_id"], NUMBER),
    ("FACTORY", permanent["permanent_contracts"]["create2_factory_addr"], ADDRESS),
    ("BRIDGEHUB", permanent["core_contracts"]["bridgehub_proxy_addr"], ADDRESS),
    ("VK_BOOJUM", genesis["prover"]["fflonk_snark_wrapper_vk_hash"], WORD),
    ("VK_AIRBENDER", genesis["prover"]["airbender_snark_wrapper_vk_hash"], WORD),
    ("VERIFIER_NAME", verifier_name, r"\w+"),
]
for key, name in [("FFLONK", "EraVerifierFflonk"), ("AIRBENDER", "AirbenderVerifierPlonk"),
                  ("VERIFIER", verifier_name), ("DEFAULT_UPGRADE", "DefaultUpgrade")]:
    facts.append((f"INIT_HASH_{key}", evm[f"l1-contracts/{name}"]["evmBytecodeHash"], WORD))
    facts.append((f"RUNTIME_HASH_{key}", evm[f"l1-contracts/{name}"]["evmDeployedBytecodeHash"], WORD))
for name, value, pattern in facts:
    # str() keeps a bool or a float from passing as a number.
    if not re.fullmatch(pattern, str(value)):
        sys.exit(f"  {name}: malformed {value!r}")
    print(f"export {name}='{value}'")
PYINPUTS
# shellcheck disable=SC1091
. "$S/inputs.env"
# Mirror ERA_TEST_CREATE_CHAIN_ID (DefaultCTMUpgrade.s.sol) and TEST_CREATE_CHAIN_SALT (CTMUpgrade_v34_1Era.s.sol).
export TEST_CHAIN_ID=555 TEST_CREATE_CHAIN_SALT=5
# Any non-zero value: it only tells the node. protocol_ops chain set-upgrade-timestamp sends the real one.
export TS=1
TESTNET_LC=$(tr 'A-Z' 'a-z' <<< "$TESTNET")
MAX_UINT=$(python3 -c 'print((1 << 256) - 1)')
ZERO=0x0000000000000000000000000000000000000000

# ---------------------------------------------------------------- the RPC
if [ -n "${L1_RPC_URL:-}" ]; then
  RPC=$L1_RPC_URL
else
  RPC=http://127.0.0.1:$PORT
  # Never fund or send to another session's anvil.
  if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then die "port $PORT is in use; set PORT"; fi
  anvil --fork-url "$L1_FORK_URL" ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} --port "$PORT" \
    --auto-impersonate --disable-block-gas-limit --silent > "$S/anvil.log" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 60); do
    kill -0 "$ANVIL_PID" 2>/dev/null || break
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
  done
  kill -0 "$ANVIL_PID" 2>/dev/null || die "anvil exited (log: $S/anvil.log)"
fi
export RPC
echo "RPC block: $(cast block-number --rpc-url "$RPC")"
[ "$(cast chain-id --rpc-url "$RPC")" = "$L1_CHAIN_ID" ] || die "the RPC is not chain $L1_CHAIN_ID"
if [ "$PUBLISHED_ONLY" = "0" ]; then
  # Fork guard: everything below may fund accounts and send as their real owners.
  cast rpc anvil_nodeInfo --rpc-url "$RPC" > /dev/null 2>&1 || die "refusing to send: the RPC is not an Anvil fork"
  echo "fork: $(cast rpc web3_clientVersion --rpc-url "$RPC" | python3 "$S/unwrap.py")"
fi

# ---------------------------------------------------------------- facts from the chain
# fact NAME CAST_CALL_ARGS… — one read, exported; a failed read, a zero or a non-address stops the run.
fact() {
  local v
  v=$(call "${@:2}" 2> "$S/fact.err") || v=
  [[ $v =~ ^0x[0-9a-fA-F]{40}$ && ! $v =~ ^0x0{40}$ ]] || die "$1 unreadable (${v:-no answer}): cast call ${*:2}"
  export "$1=$v"
}
# word NAME CAST_CALL_ARGS… — the same for a bytes32.
word() {
  local v
  v=$(call "${@:2}" 2> "$S/fact.err") || v=
  [[ $v =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$1 unreadable (${v:-no answer}): cast call ${*:2}"
  export "$1=$v"
}
# Stable across the upgrade, so --published-only reads them too.
fact CAH "$BRIDGEHUB" 'chainAssetHandler()(address)'
fact SN "$CTM" 'serverNotifierAddress()(address)'
fact VT "$CTM" 'validatorTimelockPostV29()(address)'
fact OLD_VERIFIER "$CTM" 'protocolVersionVerifier(uint256)(address)' "$OLD"
fact OLD_AIRBENDER "$OLD_VERIFIER" 'AIRBENDER_VERIFIER()(address)'
word OLD_VK "$OLD_VERIFIER" 'verificationKeyHash()(bytes32)'
word OLD_VK_BOOJUM "$OLD_VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 0
word OLD_VK_AIRBENDER "$OLD_VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 2

# ---------------------------------------------------------------- 1. prepare
if [ -n "${ECOSYSTEM_TOML:-}" ] || [ "$PUBLISHED_ONLY" = "1" ]; then
  echo "using the prepared output at $OUT"
  [ -f "$OUT" ] || die "$OUT not found"
else
  # As protocol_ops does: a dry run, then only the deployer's transactions, sent impersonated with gas the fork
  # estimates (Sepolia charges far more per deployed byte than forge's simulation assumes). forge builds into a scratch
  # dir: the script deploys the CI build it reads from out/, which a local compile must not overwrite.
  FORGE_OUT=${FOUNDRY_OUT:-$S/forge/out}
  FORGE_CACHE=${FOUNDRY_CACHE_PATH:-$S/forge/cache}
  realpath_lc() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]).lower())' "$1"; }
  for d in "$FORGE_OUT" "$FORGE_CACHE"; do
    case "$(realpath_lc "$d")/" in "$(realpath_lc "$WT")/out/"* | "$(realpath_lc "$WT")/cache-forge/"*)
      die "FOUNDRY_OUT and FOUNDRY_CACHE_PATH must be outside l1-contracts/out and cache-forge: they hold the CI build" ;;
    esac
  done
  cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null
  mkdir -p "$(dirname "$OUT")"
  # Never assert against an output left over from an earlier run; only a broadcast log of this run counts.
  rm -f "$OUT"
  touch "$S/before-prepare"
  PREPARE_EXIT=0
  (cd "$WT" && FOUNDRY_OUT=$FORGE_OUT FOUNDRY_CACHE_PATH=$FORGE_CACHE forge script \
    deploy-scripts/upgrade/v34-era/CTMUpgrade_v34_1Era.s.sol:CTMUpgrade_v34_1Era \
    --sig 'prepare(string,string,string)' "/upgrade-envs/permanent-values/$UPGRADE_ENV.toml" \
    "/upgrade-envs/v0.34.1-era/$UPGRADE_ENV.toml" "$OUT_REL" \
    --rpc-url "$RPC" --sender "$DEPLOYER" > "$S/prepare.log" 2>&1) || PREPARE_EXIT=$?
  echo "prepare (dry run) exit: $PREPARE_EXIT"
  grep -E 'v34\.1:|Error|revert' "$S/prepare.log" | tail -8 || true
  [ "$PREPARE_EXIT" = "0" ] && [ -f "$OUT" ] || die "prepare did not produce an output (log: $S/prepare.log)"
  BROADCAST_LOG=$(find "$WT/broadcast/CTMUpgrade_v34_1Era.s.sol" -name 'prepare-latest.json' -newer "$S/before-prepare" | head -1)
  [ -n "$BROADCAST_LOG" ] || die "prepare wrote no transaction log"
  # Forge's deploys of the script's own deploy-scripts/ libraries never reach the bundle (protocol_ops drops them).
  python3 - "$BROADCAST_LOG" > "$S/deployer_txs.txt" <<'PYDRYRUN' || die "cannot read the transactions in $BROADCAST_LOG"
import json, sys
log = json.load(open(sys.argv[1]))
libs = {lib.rsplit(":", 1)[1].lower() for lib in log.get("libraries", []) if lib.startswith("deploy-scripts/")}
for t in log["transactions"]:
    if t.get("transactionType") == "CREATE2" and (t.get("contractAddress") or "").lower() in libs:
        continue
    x = t["transaction"]
    print(x.get("to") or "-", x.get("input") or x.get("data") or "0x", int(str(x.get("value") or "0x0"), 16))
PYDRYRUN
  FAILED_BEFORE=$FAILED
  N=0
  while read -r to data value <&3; do
    N=$((N + 1))
    [ "$value" = "0" ] || die "deployer transaction $N sends value $value"
    send "$DEPLOYER" "$to" "$data" "deployer transaction $N to $to (${data:0:10}…), impersonated"
  done 3< "$S/deployer_txs.txt"
  [ "$FAILED" = "$FAILED_BEFORE" ] || die "deployer transactions failed on the fork"
fi
export BROADCAST_LOG

# The output's addresses, used below only after step 2 or 3 has tied them to reviewed code.
python3 - <<'PYADDR' > "$S/addresses.env" || die "cannot read the addresses from $OUT"
import os, re, tomllib
st = tomllib.load(open(os.environ["OUT"], "rb"))["state_transition"]
for name, key in [("FFLONK", "verifier_fflonk_addr"), ("AIRBENDER", "airbender_verifier_addr"),
                  ("VERIFIER", "verifier_addr"), ("DEFAULT_UPGRADE", "default_upgrade_addr")]:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", st.get(key, "")):
        raise SystemExit(f"  state_transition.{key}: malformed {st.get(key)!r}")
    print(f"export {name}={st[key]}")
PYADDR
# shellcheck disable=SC1091
. "$S/addresses.env"

# ---------------------------------------------------------------- 2. CREATE2 provenance
echo "== CREATE2 provenance (deployer, salt, init code = reviewed bytecode + constructor args, nothing else)"
PREPARE_DIR=$(dirname "$OUT")/prepare
if [ -n "$BROADCAST_LOG" ] || { [ -n "${ECOSYSTEM_TOML:-}" ] && [ -f "$PREPARE_DIR/manifest.json" ]; }; then
  PREPARE_DIR="$PREPARE_DIR" python3 - <<'PYPROVENANCE' || fail "CREATE2 provenance (see above)"
import json, os, subprocess
E = os.environ

def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"  FAIL cast {args[0]}: {r.stderr.strip()[:400]}")
    return r.stdout.strip()

failed = 0
def ok(name, cond, detail=""):
    global failed
    print(f"  {'OK  ' if cond else 'FAIL'} {name}{'' if cond or not detail else ': ' + detail}")
    failed += not cond

# (sender, to, data, value). Forge also CREATE2-deploys the script's linked deploy-scripts/ libraries; protocol_ops
# drops those from the deploy bundle (common/forge/cast_transactions.rs), so they never reach the real chain.
txs = []
if E.get("BROADCAST_LOG"):
    log = json.load(open(E["BROADCAST_LOG"]))
    libs = {lib.rsplit(":", 1)[1].lower() for lib in log.get("libraries", []) if lib.startswith("deploy-scripts/")}
    for t in log["transactions"]:
        if t.get("transactionType") == "CREATE2" and (t.get("contractAddress") or "").lower() in libs:
            print(f"     skipped: forge's deploy of script library {t.get('contractName')} (not in the deploy bundle)")
            continue
        x = t["transaction"]
        txs.append((x["from"].lower(), (x.get("to") or "").lower(), (x.get("input") or x.get("data") or "0x").lower(),
                    int(str(x.get("value") or "0x0"), 16)))
    source = E["BROADCAST_LOG"]
else:
    prepare = E["PREPARE_DIR"]
    for b in sorted(json.load(open(prepare + "/manifest.json"))["bundles"], key=lambda b: b["index"]):
        txs += [(b["target"].lower(), t["to"].lower(), t["data"].lower(), int(str(t.get("value") or "0"), 0))
                for t in json.load(open(f"{prepare}/{b['file']}"))["transactions"]]
    source = prepare
print(f"     {len(txs)} deployer transactions from {source}")
ok("exactly 4 deployer transactions", len(txs) == 4, f"{len(txs)}")
senders = sorted({t[0] for t in txs})
ok(f"one sender ({', '.join(senders)})", len(senders) == 1)
if E.get("DEPLOYER"):
    ok("the sender is DEPLOYER", senders == [E["DEPLOYER"].lower()], f"{senders}")

factory, salt = E["FACTORY"].lower(), E["SALT"].lower()
addr = {k: E[k].lower() for k in ["FFLONK", "AIRBENDER", "VERIFIER", "DEFAULT_UPGRADE"]}
# The verifier's constructor args are this deployment's FFLONK and Airbender verifiers, each checked here too.
args = {"FFLONK": "", "AIRBENDER": "", "DEFAULT_UPGRADE": "",
        "VERIFIER": cast("abi-encode", "f(address,address)", addr["FFLONK"], addr["AIRBENDER"])[2:]}
names = {"FFLONK": "EraVerifierFflonk", "AIRBENDER": "AirbenderVerifierPlonk", "VERIFIER": E["VERIFIER_NAME"],
         "DEFAULT_UPGRADE": "DefaultUpgrade"}
matched = {}
for sender, to, data, value in txs:
    ok(f"{data[:10]} to the CREATE2 factory {factory}, no value", to == factory and value == 0, f"to {to}, value {value}")
    tx_salt, init = "0x" + data[2:66], data[66:]
    found = None
    for key in names:
        if key in matched or not init.endswith(args[key]):
            continue
        if cast("keccak", "0x" + init[: len(init) - len(args[key])]) == E[f"INIT_HASH_{key}"].lower():
            found = key
            break
    if not found:
        ok(f"init code ({len(init) // 2} bytes) is one of the four reviewed contracts with its constructor args", False)
        continue
    matched[found] = True
    address = "0x" + cast("keccak", "0xff" + factory[2:] + tx_salt[2:] + cast("keccak", "0x" + init)[2:])[-40:]
    ok(f"{names[found]}: salt = the env's, CREATE2 address = the output's {addr[found]}",
       tx_salt == salt and address == addr[found], f"salt {tx_salt}, address {address}")
missing = [names[k] for k in names if k not in matched]
ok("each of the four deployed exactly once", not missing, f"missing {missing}")
raise SystemExit(1 if failed else 0)
PYPROVENANCE
elif [ "$PUBLISHED_ONLY" = "1" ]; then
  # No init code at hand: the argument-free three follow from their reviewed creation-code hash.
  for k in FFLONK AIRBENDER DEFAULT_UPGRADE; do
    init_hash_var=INIT_HASH_$k
    h=$(cast keccak "0xff${FACTORY#0x}${SALT#0x}${!init_hash_var#0x}")
    chk "$k at CREATE2(factory, env salt, reviewed init code)" "0x${h: -40}" "${!k}"
  done
  skip "the verifier's CREATE2 provenance (no prepare/ next to $OUT)"
else
  fail "no deployer transactions: no prepare/manifest.json next to ECOSYSTEM_TOML"
fi

# ---------------------------------------------------------------- 3. deployed code and keys
echo "== Deployed code and keys"
for k in FFLONK AIRBENDER DEFAULT_UPGRADE; do
  runtime_hash_var=RUNTIME_HASH_$k
  code=$(cast code "${!k}" --rpc-url "$RPC" 2>/dev/null) || code=
  if [ -z "$code" ] || [ "$code" = "0x" ]; then fail "$k ${!k}: no code"; continue; fi
  chk "$k ${!k}: runtime keccak = AllContractsHashes.json" "$(cast keccak "$code")" "${!runtime_hash_var}"
done
code=$(cast code "$VERIFIER" --rpc-url "$RPC" 2>/dev/null) || code=
[ -n "$code" ] && [ "$code" != "0x" ] && echo "  OK   verifier $VERIFIER has code" || fail "verifier $VERIFIER: no code"
chk "verifier BOOJUM_VERIFIER = the new FFLONK verifier" "$(call "$VERIFIER" 'BOOJUM_VERIFIER()(address)')" "$FFLONK"
chk "verifier AIRBENDER_VERIFIER = the new Airbender verifier" "$(call "$VERIFIER" 'AIRBENDER_VERIFIER()(address)')" "$AIRBENDER"
chk "verifier IS_TESTNET_VERIFIER = testnet_verifier" "$(call "$VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" "$TESTNET_LC"
chk "verifier supportedProofSystems = Boojum | Airbender" "$(call "$VERIFIER" 'supportedProofSystems()(uint8)')" 3
chk "verifier verificationKeyHash() = genesis FFLONK key (what the node stores)" "$(call "$VERIFIER" 'verificationKeyHash()(bytes32)')" "$VK_BOOJUM"
chk "verifier verificationKeyHash(0) = genesis FFLONK key" "$(call "$VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 0)" "$VK_BOOJUM"
chk "verifier verificationKeyHash(2) = genesis Airbender key" "$(call "$VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 2)" "$VK_AIRBENDER"
differs "new FFLONK key differs from the old verifier's" "$VK_BOOJUM" "$OLD_VK_BOOJUM"
differs "new Airbender key differs from the old verifier's" "$VK_AIRBENDER" "$OLD_VK_AIRBENDER"

echo "== The Airbender fixture proof (test/foundry/.../fixtures/AirbenderPlonkProofFixture.sol)"
FIXTURE=$WT/test/foundry/l1/unit/concrete/state-transition/verifiers/fixtures/AirbenderPlonkProofFixture.sol
if python3 - "$FIXTURE" > "$S/fixture.txt" <<'PYFIXTURE'; then
import re, sys
src = open(sys.argv[1]).read()
words = lambda name: [int(v, 16) for _, v in sorted((int(i), v) for i, v in re.findall(rf"\b{name}\[(\d+)\] = (0x[0-9a-fA-F]+);", src))]
inputs, proof = words("inputs"), words("proof")
if (len(inputs), len(proof)) != (1, 44):
    raise SystemExit(f"  FAIL fixture: {len(inputs)} inputs and {len(proof)} proof words, expected 1 and 44")
print("[" + ",".join(map(str, inputs)) + "]")
print("[" + ",".join(map(str, proof)) + "]")
PYFIXTURE
  echo "  OK   fixture: 1 public input, 44 proof words"
  { read -r FIX_INPUTS; read -r FIX_PROOF; } < "$S/fixture.txt"
  chk "new AirbenderVerifierPlonk.verify(fixture) = true" \
    "$(call "$AIRBENDER" 'verify(uint256[],uint256[])(bool)' "$FIX_INPUTS" "$FIX_PROOF" 2> "$S/fixture.err")" true
  if out=$(call "$OLD_AIRBENDER" 'verify(uint256[],uint256[])(bool)' "$FIX_INPUTS" "$FIX_PROOF" 2> "$S/fixture.err"); then
    chk "old AirbenderVerifierPlonk $OLD_AIRBENDER rejects it (returns false)" "$out" false
  elif grep -qi revert "$S/fixture.err"; then
    echo "  OK   old AirbenderVerifierPlonk $OLD_AIRBENDER rejects it (reverts)"
  else
    fail "old AirbenderVerifierPlonk: the call failed without a revert: $(tail -1 "$S/fixture.err" | head -c 200)"
  fi
else
  fail "fixture unreadable (see above)"
fi

if [ "$PUBLISHED_ONLY" = "1" ]; then
  echo
  NOTE=
  [ "$SKIPPED" = "0" ] || NOTE=" ($SKIPPED skipped)"
  if [ "$FAILED" = "0" ]; then echo "PUBLICATION CHECK PASSED$NOTE"; DONE=1; exit 0; fi
  echo "PUBLICATION CHECK FAILED ($FAILED)"; DONE=1; exit 1
fi

# ---------------------------------------------------------------- facts for the fork flow
fact PUH "$CTM" 'owner()(address)'
fact BH_ADMIN "$BRIDGEHUB" 'admin()(address)'
word INITIAL_CUT_HASH "$CTM" 'initialCutHash()(bytes32)'
word FDD_HASH "$CTM" 'initialForceDeploymentHash()(bytes32)'
UPGRADER_ROLE=$(cast keccak UPGRADER_ROLE)
: > "$S/chains.txt"
for id in $CHAIN_IDS; do
  fact DIAMOND "$CTM" 'getZKChain(uint256)(address)' "$id"
  fact CHAIN_ADMIN "$CTM" 'getChainAdmin(uint256)(address)' "$id"
  fact CHAIN_ADMIN_OWNER "$CHAIN_ADMIN" 'owner()(address)'
  n=$(call "$VT" 'getRoleMemberCount(address,bytes32)(uint256)' "$DIAMOND" "$UPGRADER_ROLE" | first) || n=
  case "$n" in '' | *[!0-9]*) die "chain $id: UPGRADER_ROLE member count unreadable" ;; 0) UPGRADER=$ZERO ;;
    *) fact UPGRADER "$VT" 'getRoleMember(address,bytes32,uint256)(address)' "$DIAMOND" "$UPGRADER_ROLE" 0 ;; esac
  echo "$id $DIAMOND $CHAIN_ADMIN $CHAIN_ADMIN_OWNER $UPGRADER" >> "$S/chains.txt"
done
FIRST_ID=${CHAIN_IDS%% *}
word BASE_TOKEN "$BRIDGEHUB" 'baseTokenAssetId(uint256)(bytes32)' "$FIRST_ID"
export PUH BH_ADMIN INITIAL_CUT_HASH FDD_HASH BASE_TOKEN MAX_UINT

echo "== The inputs against the chain"
FAILED_BEFORE=$FAILED
chk "PUH: the CTM's owner() = the bridgehub's owner()" "$(call "$BRIDGEHUB" 'owner()(address)')" "$PUH"
chk "the CTM's BRIDGE_HUB() = bridgehub_proxy_addr" "$(call "$CTM" 'BRIDGE_HUB()(address)')" "$BRIDGEHUB"
chk "CTM protocolVersion = v0.34.0 (old)" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$OLD"
chk "CTM upgradeCutHash(old) = 0: no upgrade registered yet" "$(call "$CTM" 'upgradeCutHash(uint256)(bytes32)' "$OLD")" \
  0x0000000000000000000000000000000000000000000000000000000000000000
chk "old verifier IS_TESTNET_VERIFIER = testnet_verifier" "$(call "$OLD_VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" "$TESTNET_LC"
while read -r id diamond admin owner upgrader <&3; do
  chk "chain $id: the bridgehub's chainTypeManager = the CTM" "$(call "$BRIDGEHUB" 'chainTypeManager(uint256)(address)' "$id")" "$CTM"
  chk "chain $id: protocol version = old" "$(call "$diamond" 'getProtocolVersion()(uint256)' | first)" "$OLD"
  chk "chain $id: verifier = the old version's" "$(call "$diamond" 'getVerifier()(address)')" "$OLD_VERIFIER"
  chk "chain $id: settles on L1" "$(call "$diamond" 'getSettlementLayer()(address)')" "$ZERO"
  echo "     chain $id: diamond $diamond, ChainAdmin $admin (owner $owner), UPGRADER_ROLE holder $upgrader"
done 3< "$S/chains.txt"
[ "$FAILED" = "$FAILED_BEFORE" ] || die "the inputs differ from the chain"

# ---------------------------------------------------------------- 4. the output, decoded
# Only what step 5 can't show on its own: the cut, the exact governance calls, the test calls' arguments and the keys
# people read. Also builds each chain's calls as `protocol_ops chain set-upgrade-timestamp` and `chain upgrade` do;
# the output has none. Writes $S/stage{0,1,2}.txt, $S/chain_<id>.env and $S/test_create_chain.txt.
python3 - <<'PYSTATIC' || fail "decoded output (see above)"
import json, os, subprocess, tomllib, traceback
E = os.environ

def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"cast {args[0]}: {r.stderr.strip()[:400]}")
    return r.stdout.strip()

def cast_json(*args):
    v = json.loads(cast(*args))
    # cast >= 1.8 wraps --json output in {"schema_version", "success", "data"}.
    return v["data"] if isinstance(v, dict) and "schema_version" in v else v

def num(x):
    try:
        return int(str(x), 0)
    except ValueError:
        return None

CUT = "((address,uint8,bool,bytes4[])[],address,bytes)"
L2TX = "(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes)"
PU = f"({L2TX},bytes32,bytes32,bytes32,address,(bytes32,bytes32,bytes32),bytes,bytes,uint256,uint256)"
CALLS = "(address,uint256,bytes)[]"
MULTICALL = "multicall((address,uint256,bytes)[],bool)"
UPGRADE_CHAIN = f"upgradeChainFromVersion(address,uint256,{CUT})"
CREATE = "createNewChain(uint256,address,bytes32,uint256,address,bytes,bytes[])"
ZERO, Z32 = "0x" + "00" * 20, "0x" + "00" * 32
calldata = lambda s, *args: cast("calldata", s, *args)
calls_of = lambda data: [[c[0], num(c[1]), c[2]] for c in cast_json("abi-decode", "--json", "--input", f"f({CALLS})", data)[0]]

def norm(v):
    if isinstance(v, str):
        return v.lower()
    if isinstance(v, (list, tuple)):
        return [norm(x) for x in v]
    return v

def short(v):
    text = v if isinstance(v, str) else json.dumps(v)
    return text if len(text) <= 160 else f"{text[:80]}…({len(text)} chars)…{text[-40:]}"

def where(got, expected):
    """The differing elements, and for strings the first differing character."""
    if isinstance(got, list) and isinstance(expected, list) and len(got) == len(expected):
        return "; ".join(f"[{i}] {where(g, e)}" for i, (g, e) in enumerate(zip(got, expected)) if g != e)
    if isinstance(got, str) and isinstance(expected, str):
        i = next((k for k, (a, b) in enumerate(zip(got, expected)) if a != b), min(len(got), len(expected)))
        return f"from char {i}: expected …{expected[max(0, i - 8):i + 32]}…, got …{got[max(0, i - 8):i + 32]}…"
    return f"expected {short(expected)}, got {short(got)}"

failed = 0
def check(name, got, expected):
    global failed
    got, expected = norm(got), norm(expected)
    if got == expected:
        print(f"  OK   {name}")
        return
    failed += 1
    print(f"  FAIL {name}: {where(got, expected)}")

def section(title, body):
    """A section that can't run (missing key, undecodable value) is one failure, not the end of the step."""
    global failed
    print(f"== {title}")
    try:
        body()
    except Exception as e:
        failed += 1
        print(f"  FAIL {title}: {type(e).__name__}: {e}")
        traceback.print_exc(limit=1)

eco = tomllib.load(open(E["OUT"], "rb"))
get = lambda table, key: eco.get(table, {}).get(key)
chains = [line.split() for line in open(E["S"] + "/chains.txt")]
# The cut createNewPatchUpgrade builds on chain: no facets, DefaultUpgrade, upgrade(emptyProposedUpgrade(new)).
empty_tx = "(0,0,0,0,0,0,0,0,0,0,[0,0,0,0],0x,0x,[],0x,0x)"
proposed = f"({empty_tx},{Z32},{Z32},{Z32},{ZERO},({Z32},{Z32},{Z32}),0x,0x,0,{num(E['NEW'])})"
cut = f"([],{E['DEFAULT_UPGRADE']},{calldata(f'upgrade({PU})', proposed)})"
expected_cut = cast("abi-encode", f"f({CUT})", cut)
cut_hash = cast("keccak", expected_cut)
open(E["S"] + "/expected.env", "w").write(f"export EXP_CUT_HASH={cut_hash}\nexport EXP_CUT_DATA={expected_cut}\n")

def the_cut():
    check("upgrade_cut_data = ([], DefaultUpgrade, upgrade(emptyProposedUpgrade(new)))", get("contracts_config", "upgrade_cut_data"), expected_cut)
    check("upgrade_cut_hash = its keccak", get("contracts_config", "upgrade_cut_hash"), cut_hash)

def governance():
    stages = {s: calls_of(get("governance_calls", f"stage{s}_calls")) for s in range(3)}
    for s in range(3):
        open(E["S"] + f"/stage{s}.txt", "w").write("".join(f"{c[0]} {c[2]}\n" for c in stages[s]))
    pause, unpause = calldata("pauseMigration()"), calldata("unpauseMigration()")
    patch = calldata("createNewPatchUpgrade(uint256,uint256,uint256,address,address)", E["OLD"], E["MAX_UINT"], E["NEW"],
                     E["VERIFIER"], E["DEFAULT_UPGRADE"])
    check("createNewPatchUpgrade selector", patch[:10], "0x81a8e48e")
    check("stage 0 = [ChainAssetHandler.pauseMigration()]", stages[0], [[E["CAH"], 0, pause]])
    check("stage 1 = [ChainAssetHandler.pauseMigration(), CTM.createNewPatchUpgrade(old, 2^256-1, new, verifier, DefaultUpgrade)]",
          stages[1], [[E["CAH"], 0, pause], [E["CTM"], 0, patch]])
    check("stage 2 = [ChainAssetHandler.unpauseMigration()]", stages[2], [[E["CAH"], 0, unpause]])

def test_calls():
    # The creation params themselves are checked on the fork: createNewChain reverts unless they hash to the CTM's.
    create = calls_of(get("test_upgrade_calls", "test_create_chain_era"))
    check("test_create_chain_era is one call to the bridgehub, no value", [[c[0], c[1], c[2][:10]] for c in create],
          [[E["BRIDGEHUB"], 0, cast("sig", CREATE)]])
    args = cast_json("calldata-decode", "--json", CREATE, create[0][2])
    check(f"test_create_chain_era: createNewChain({E['TEST_CHAIN_ID']}, CTM, chain {chains[0][0]}'s base token, salt "
          f"{E['TEST_CREATE_CHAIN_SALT']}, bridgehub admin, …, []), from the bridgehub admin",
          [num(args[0]), args[1], args[2], num(args[3]), args[4], args[6], get("test_upgrade_calls", "test_create_chain_era_caller")],
          [num(E["TEST_CHAIN_ID"]), E["CTM"], E["BASE_TOKEN"], num(E["TEST_CREATE_CHAIN_SALT"]), E["BH_ADMIN"], [], E["BH_ADMIN"]])
    open(E["S"] + "/test_create_chain.txt", "w").write(f"{create[0][0]} {create[0][2]}\n")
    cid, diamond, admin = chains[0][:3]
    check(f"test_upgrade_chain_era = [chain {cid}.upgradeChainFromVersion(diamond, old, cut)], from its ChainAdmin",
          [calls_of(get("test_upgrade_calls", "test_upgrade_chain_era")), get("test_upgrade_calls", "test_upgrade_chain_era_caller")],
          [[[diamond, 0, calldata(UPGRADE_CHAIN, diamond, E["OLD"], cut)]], admin])

def other_keys():
    keys = [
        ("contracts_config", "old_protocol_version", num, E["OLD"]), ("contracts_config", "new_protocol_version", num, E["NEW"]),
        ("contracts_config", "old_protocol_version_deadline", num, E["MAX_UINT"]),
        ("contracts_config", "chain_type_manager", str, E["CTM"]), ("state_transition", "chain_type_manager_proxy", str, E["CTM"]),
        ("contracts_config", "old_verifier", str, E["OLD_VERIFIER"]), ("contracts_config", "old_verifier_vk_hash", str, E["OLD_VK"]),
        ("contracts_config", "old_boojum_vk_hash", str, E["OLD_VK_BOOJUM"]),
        ("contracts_config", "old_airbender_vk_hash", str, E["OLD_VK_AIRBENDER"]),
        ("contracts_config", "verifier", str, E["VERIFIER"]), ("contracts_config", "verifier_vk_hash", str, E["VK_BOOJUM"]),
        ("contracts_config", "boojum_vk_hash", str, E["VK_BOOJUM"]), ("contracts_config", "airbender_vk_hash", str, E["VK_AIRBENDER"]),
        ("deployed_addresses", "chain_asset_handler_addr", str, E["CAH"]),
        ("deployed_addresses", "server_notifier_proxy_addr", str, E["SN"]),
        ("deployed_addresses", "validator_timelock_addr", str, E["VT"]),
        ("contracts", "create2_factory_addr", str, E["FACTORY"]), ("contracts", "create2_factory_salt", str, E["SALT"]),
    ]
    bad = [f"{t}.{k}" for t, k, kind, want in keys
           if get(t, k) is None or norm(num(get(t, k)) if kind is num else str(get(t, k))) != norm(num(want) if kind is num else want)]
    check(f"the {len(keys)} other output keys = the env's, the chain's and the genesis' (mismatches listed)", bad, [])

def chain_calls():
    for cid, diamond, admin, owner, upgrader in chains:
        notify = f"[({E['SN']},0,{calldata('setUpgradeTimestamp(uint256,uint256)', cid, E['TS'])})]"
        inner = calldata(UPGRADE_CHAIN, diamond, E["OLD"], cut)
        sends = {
            "LEGACY_TS_CALLDATA": calldata("setUpgradeTimestamp(uint256,uint256)", E["NEW"], E["TS"]),
            "SN_TS_CALLDATA": calldata(MULTICALL, notify, "true"),
            "VT_CALLDATA": inner,
            "CA_CALLDATA": calldata(MULTICALL, f"[({diamond},0,{inner})]", "true"),
        }
        # Built here from cast's output, never copied from the output being checked: bash sources this file.
        open(E["S"] + f"/chain_{cid}.env", "w").write("".join(f"{k}={v}\n" for k, v in sends.items()))
        print(f"  OK   chain {cid}: calls built")

section("The cut", the_cut)
section("Governance calls", governance)
section("Test calls", test_calls)
section("The output's other keys", other_keys)
section("Each chain's calls, as protocol_ops chain set-upgrade-timestamp and chain upgrade build them", chain_calls)
raise SystemExit(1 if failed else 0)
PYSTATIC
[ -f "$S/expected.env" ] || die "the decoded-output step wrote no expectations"
# shellcheck disable=SC1091
. "$S/expected.env"

# ---------------------------------------------------------------- 5. the fork flow
# reverts LABEL FROM TO DATA ERROR_SIGNATURE — eth_call must revert with that error.
reverts() {
  local out sel
  if out=$(cast call --from "$2" "$3" "$4" --rpc-url "$RPC" 2>&1); then fail "$1: did not revert"; return 0; fi
  grep -qi revert <<< "$out" || { fail "$1: failed without a revert: $(tail -1 <<< "$out" | head -c 200)"; return 0; }
  # cast prints the error's selector, or its name when it can decode it.
  sel=$(cast sig "$5")
  if grep -qiE "${sel#0x}|${5%%(*}" <<< "$out"; then echo "  OK   $1"; else fail "$1: reverted with $(tail -1 <<< "$out" | head -c 200)"; fi
}
# emitted LABEL ADDRESS EVENT_SIGNATURE TOPICS DATA — $S/receipt.json holds exactly one such log with those leading
# indexed arguments (space-separated numbers) and exactly that data.
emitted() {
  if python3 - "$S/receipt.json" "$2" "$(cast keccak "$3")" "$4" "$5" <<'PYEMITTED'; then echo "  OK   $1"; else fail "$1"; fi
import json, sys
receipt, address, topic0, topics, data = sys.argv[1:]
want = [int(t, 0) for t in topics.split()]
if not want:
    sys.exit("     no topics given")
logs = [l for l in json.load(open(receipt))["logs"] if l["address"].lower() == address.lower() and l["topics"][:1] == [topic0]
        and [int(t, 16) for t in l["topics"][1:1 + len(want)]] == want]
sys.exit(0 if len(logs) == 1 and logs[0]["data"].lower() == data.lower() else 1)
PYEMITTED
}
receipt_block() { python3 -c 'import json, sys; print(int(json.load(open(sys.argv[1]))["blockNumber"], 16))' "$S/receipt.json"; }
# dump DIAMOND FILE — what a patch must not change: base-system hashes, the pending L2 upgrade, batch counters, proof
# systems, admin, and every facet's selectors with their freezability. Any failed read fails the dump.
dump() {
  DIAMOND_ADDR=$1 python3 - > "$2" <<'PYDUMP'
import json, os, subprocess
E = os.environ
cast = lambda *a: subprocess.run(["cast", *a, "--rpc-url", E["RPC"]], capture_output=True, text=True, check=True).stdout.strip()
d = E["DIAMOND_ADDR"]
for getter in ["getL2BootloaderBytecodeHash()(bytes32)", "getL2DefaultAccountBytecodeHash()(bytes32)",
               "getL2EvmEmulatorBytecodeHash()(bytes32)", "getL2SystemContractsUpgradeTxHash()(bytes32)",
               "getTotalBatchesCommitted()(uint256)", "getTotalBatchesVerified()(uint256)",
               "getTotalBatchesExecuted()(uint256)", "disabledProofSystems()((bool,bool))", "getAdmin()(address)"]:
    print(getter.split("(")[0], cast("call", d, getter))
facets = json.loads(subprocess.run(["cast", "abi-decode", "--json", "f()((address,bytes4[])[])", cast("call", d, "facets()")],
                                   capture_output=True, text=True, check=True).stdout)
# cast >= 1.8 wraps --json output in {"schema_version", "success", "data"}.
facets = (facets["data"] if isinstance(facets, dict) and "schema_version" in facets else facets)[0]
for facet, selectors in sorted(facets):
    for s in sorted(selectors):
        print("facet", facet.lower(), s.lower(), cast("call", d, "isFunctionFreezable(bytes4)(bool)", s))
PYDUMP
}

ANYONE=0x1111111111111111111111111111111111111111
for a in "$PUH" "$BH_ADMIN" "$ANYONE"; do cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null; done
while read -r _ _ _ owner upgrader <&3; do
  for a in "$owner" "$upgrader"; do
    [ "$a" = "$ZERO" ] || cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" > /dev/null
  done
done 3< "$S/chains.txt"

B_OWNER=$(call "$CTM" 'owner()(address)')
B_ADMIN=$(call "$CTM" 'admin()(address)')
B_GENESIS_UPGRADE=$(call "$CTM" 'l1GenesisUpgrade()(address)')
B_PARAMS_BLOCK=$(call "$CTM" 'newChainCreationParamsBlock(uint256)(uint256)' "$OLD" | first)
echo "     CTM newChainCreationParamsBlock(old) = $B_PARAMS_BLOCK"

for n in 0 1 2; do [ -f "$S/stage$n.txt" ] || die "no stage $n calls from step 4 (see above)"; done
echo "== Before governance"
read -r _ PATCH_DATA < <(sed -n 2p "$S/stage1.txt" 2> /dev/null) || die "no stage 1 createNewPatchUpgrade call (see step 4)"
reverts "createNewPatchUpgrade without paused migrations reverts with MigrationsNotPaused" "$PUH" "$CTM" "$PATCH_DATA" 'MigrationsNotPaused()'
while read -r id diamond admin owner upgrader <&3; do
  [ -f "$S/chain_$id.env" ] || { fail "chain $id: no calls from step 4 (see above)"; continue; }
  # shellcheck disable=SC1090
  . "$S/chain_$id.env"
  reverts "chain $id: the ServerNotifier timestamp reverts with CutDataForProtocolVersionNotAvailable" \
    "$owner" "$admin" "$SN_TS_CALLDATA" 'CutDataForProtocolVersionNotAvailable(uint256)'
  if [ "$upgrader" = "$ZERO" ]; then
    fail "chain $id: no UPGRADER_ROLE holder on the ValidatorTimelock"
  else
    reverts "chain $id: the ValidatorTimelock upgrade from $upgrader reverts with HashMismatch" \
      "$upgrader" "$VT" "$VT_CALLDATA" 'HashMismatch(bytes32,bytes32)'
  fi
done 3< "$S/chains.txt"

echo "== Governance, as the PUH"
while read -r target data <&3; do send "$PUH" "$target" "$data" "stage 0 ${data:0:10} -> $target"; done 3< "$S/stage0.txt"
chk "migrations paused" "$(call "$CAH" 'migrationPaused()(bool)')" true
# Anyone can unpause in between (PUH.reinforceUnfreeze needs only an unfrozen protocol), and so does every emergency
# execution: stage 1 must re-pause before createNewPatchUpgrade.
send "$ANYONE" "$PUH" "$(cast calldata 'reinforceUnfreeze()')" "PUH.reinforceUnfreeze() from $ANYONE"
chk "migrations unpaused by reinforceUnfreeze()" "$(call "$CAH" 'migrationPaused()(bool)')" false
PATCH_BLOCK=
while read -r target data <&3; do
  send "$PUH" "$target" "$data" "stage 1 ${data:0:10} -> $target"
  [ "$(lc "$target")" = "$(lc "$CTM")" ] && PATCH_BLOCK=$(receipt_block) || true
done 3< "$S/stage1.txt"
TOPIC_CUT_DATA=$(cast keccak "NewUpgradeCutData(uint256,((address,uint8,bool,bytes4[])[],address,bytes))")
python3 - "$S/receipt.json" "$CTM" "$TOPIC_CUT_DATA" "$OLD" "$NEW" "$EXP_CUT_DATA" <<'PYCUTDATA' \
  && echo "  OK   createNewPatchUpgrade emitted NewUpgradeCutData(old, cut) and NewUpgradeCutData(new, cut), cut = the expected one" \
  || fail "NewUpgradeCutData events (protocol_ops chain commands read the cut from them)"
import json, sys
receipt, ctm, topic0, old, new, cut = sys.argv[1:]
logs = [l for l in json.load(open(receipt))["logs"] if l["address"].lower() == ctm.lower() and l["topics"][0] == topic0]
sys.exit(0 if sorted(int(l["topics"][1], 16) for l in logs) == sorted([int(old), int(new)])
         and all(l["data"].lower() == cut.lower() for l in logs) else 1)
PYCUTDATA
while read -r target data <&3; do send "$PUH" "$target" "$data" "stage 2 ${data:0:10} -> $target"; done 3< "$S/stage2.txt"

echo "== The CTM after governance"
chk "protocolVersion = new" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$NEW"
chk "protocolVersionVerifier(new) = the new verifier" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW")" "$VERIFIER"
chk "protocolVersionVerifier(old) unchanged" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$OLD")" "$OLD_VERIFIER"
chk "upgradeCutHash(old) = upgrade_cut_hash" "$(call "$CTM" 'upgradeCutHash(uint256)(bytes32)' "$OLD")" "$EXP_CUT_HASH"
chk "upgradeCutDataBlock(old) = stage 1's block" "$(call "$CTM" 'upgradeCutDataBlock(uint256)(uint256)' "$OLD" | first)" "$PATCH_BLOCK"
chk "protocolVersionDeadline(old) = 2^256-1" "$(call "$CTM" 'protocolVersionDeadline(uint256)(uint256)' "$OLD" | first)" "$MAX_UINT"
chk "protocolVersionDeadline(new) = 2^256-1" "$(call "$CTM" 'protocolVersionDeadline(uint256)(uint256)' "$NEW" | first)" "$MAX_UINT"
case "$B_PARAMS_BLOCK" in '' | 0) fail "newChainCreationParamsBlock(old) was ${B_PARAMS_BLOCK:-unreadable}" ;; esac
chk "newChainCreationParamsBlock(new) = newChainCreationParamsBlock(old)" \
  "$(call "$CTM" 'newChainCreationParamsBlock(uint256)(uint256)' "$NEW" | first)" "$B_PARAMS_BLOCK"
chk "initialCutHash unchanged" "$(call "$CTM" 'initialCutHash()(bytes32)')" "$INITIAL_CUT_HASH"
chk "initialForceDeploymentHash unchanged" "$(call "$CTM" 'initialForceDeploymentHash()(bytes32)')" "$FDD_HASH"
chk "l1GenesisUpgrade unchanged" "$(call "$CTM" 'l1GenesisUpgrade()(address)')" "$B_GENESIS_UPGRADE"
chk "owner unchanged" "$(call "$CTM" 'owner()(address)')" "$B_OWNER"
chk "admin unchanged" "$(call "$CTM" 'admin()(address)')" "$B_ADMIN"
chk "migrations unpaused" "$(call "$CAH" 'migrationPaused()(bool)')" false

# after_upgrade LABEL ID DIAMOND BEFORE_DUMP — the chain is on the new version with the new verifier, nothing else moved.
after_upgrade() {
  chk "$1: protocol version = new" "$(call "$3" 'getProtocolVersion()(uint256)' | first)" "$NEW"
  chk "$1: verifier = the new verifier" "$(call "$3" 'getVerifier()(address)')" "$VERIFIER"
  if dump "$3" "$S/after.txt" 2> "$S/dump.err"; then
    if diff "$4" "$S/after.txt" > "$S/dump.diff"; then
      echo "  OK   $1: base-system hashes, pending L2 upgrade, batch counters, proof systems, admin, facets unchanged"
    else
      fail "$1: state changed: $(head -c 400 "$S/dump.diff")"
    fi
  else
    fail "$1: state unreadable: $(head -c 300 "$S/dump.err")"
  fi
}

while read -r id diamond admin owner upgrader <&3; do
  [ -f "$S/chain_$id.env" ] || { fail "chain $id: no calls from step 4 (see above)"; continue; }
  # shellcheck disable=SC1090
  . "$S/chain_$id.env"
  echo "== Chain $id: timestamp, as protocol_ops chain set-upgrade-timestamp's bundle, from the ChainAdmin's owner"
  [ "$upgrader" = "$ZERO" ] || reverts "chain $id: the ValidatorTimelock upgrade before the timestamp reverts with UpgradeTimestampNotReached" \
    "$upgrader" "$VT" "$VT_CALLDATA" 'UpgradeTimestampNotReached(uint256,uint256)'
  send "$owner" "$admin" "$LEGACY_TS_CALLDATA" "chain $id: ChainAdmin.setUpgradeTimestamp(new, $TS), directly (onlyOwner; pre-v31 nodes)"
  chk "chain $id: ChainAdmin protocolVersionToUpgradeTimestamp(new) = $TS" \
    "$(call "$admin" 'protocolVersionToUpgradeTimestamp(uint256)(uint256)' "$NEW" | first)" "$TS"
  send "$owner" "$admin" "$SN_TS_CALLDATA" "chain $id: ChainAdmin multicall(ServerNotifier.setUpgradeTimestamp($id, $TS))"
  emitted "chain $id: UpgradeTimestampUpdated($id, old, $TS) emitted by the ServerNotifier" "$SN" \
    'UpgradeTimestampUpdated(uint256,uint256,uint256)' "$id $OLD" "$(cast abi-encode 'f(uint256)' "$TS")"
  chk "chain $id: protocolVersionToUpgradeTimestamp($id, old) = $TS" \
    "$(call "$SN" 'protocolVersionToUpgradeTimestamp(uint256,uint256)(uint256)' "$id" "$OLD" | first)" "$TS"

  if dump "$diamond" "$S/before_$id.txt" 2> "$S/dump.err"; then
    echo "     chain $id before: $(grep -c '^facet' "$S/before_$id.txt") selectors; batches committed/verified/executed" \
      "$(awk '/^getTotalBatches/ {printf "%s ", $2}' "$S/before_$id.txt")(no drain: in-flight batches stay)"
  else
    die "chain $id: state unreadable: $(head -c 300 "$S/dump.err")"
  fi
  SNAPSHOT=$(cast rpc evm_snapshot --rpc-url "$RPC" | python3 "$S/unwrap.py")
  echo "== Chain $id: upgrade through the ValidatorTimelock, from the UPGRADER_ROLE holder"
  # Whether the env's node can send this depends on which contract it proves through: see the README.
  echo "     the server's path, if the node proves through this ValidatorTimelock as the UPGRADER_ROLE holder"
  if [ "$upgrader" = "$ZERO" ]; then
    fail "chain $id: no UPGRADER_ROLE holder"
  else
    send "$upgrader" "$VT" "$VT_CALLDATA" "chain $id: ValidatorTimelock.upgradeChainFromVersion from $upgrader"
    after_upgrade "chain $id (ValidatorTimelock)" "$id" "$diamond" "$S/before_$id.txt"
  fi
  [ "$(cast rpc evm_revert "$SNAPSHOT" --rpc-url "$RPC" | python3 "$S/unwrap.py")" = "true" ] || die "evm_revert($SNAPSHOT) failed"
  chk "chain $id: back on old after evm_revert" "$(call "$diamond" 'getProtocolVersion()(uint256)' | first)" "$OLD"

  echo "== Chain $id: upgrade as protocol_ops chain upgrade's bundle, from the ChainAdmin's owner"
  send "$owner" "$admin" "$CA_CALLDATA" "chain $id: ChainAdmin multicall(upgradeChainFromVersion)"
  after_upgrade "chain $id (ChainAdmin)" "$id" "$diamond" "$S/before_$id.txt"
  [ "$upgrader" = "$ZERO" ] || reverts "chain $id: the ValidatorTimelock upgrade afterwards reverts with ProtocolIdMismatch" \
    "$upgrader" "$VT" "$VT_CALLDATA" 'ProtocolIdMismatch(uint256,uint256)'
done 3< "$S/chains.txt"

echo "== Test chain $TEST_CHAIN_ID, created by the bridgehub admin"
chk "chain $TEST_CHAIN_ID not registered yet" "$(call "$BRIDGEHUB" 'getZKChain(uint256)(address)' "$TEST_CHAIN_ID")" "$ZERO"
NEW_CHAIN=
if [ -f "$S/test_create_chain.txt" ]; then
  read -r TC_TARGET TC_DATA < "$S/test_create_chain.txt"
  send "$BH_ADMIN" "$TC_TARGET" "$TC_DATA" "Bridgehub.createNewChain($TEST_CHAIN_ID)"
  NEW_CHAIN=$(call "$BRIDGEHUB" 'getZKChain(uint256)(address)' "$TEST_CHAIN_ID") || NEW_CHAIN=
fi
if [ -n "$NEW_CHAIN" ] && [ "$NEW_CHAIN" != "$ZERO" ]; then
  chk "test chain: protocol version = new" "$(call "$NEW_CHAIN" 'getProtocolVersion()(uint256)' | first)" "$NEW"
  chk "test chain: verifier = the new verifier" "$(call "$NEW_CHAIN" 'getVerifier()(address)')" "$VERIFIER"
else
  fail "test chain not registered (or no test_create_chain_era call from step 4)"
fi

echo
DONE=1
NOTE=
[ "$SKIPPED" = "0" ] || NOTE=" ($SKIPPED skipped)"
if [ "$FAILED" = "0" ]; then
  echo "REHEARSAL PASSED$NOTE"
else
  echo "REHEARSAL FAILED ($FAILED)$NOTE"
  exit 1
fi
