#!/usr/bin/env bash
# Rehearse the v34 Era upgrade of one environment on an L1 fork and check the resulting L1 state. The
# environment is UPGRADE_ENV (stage, testnet3, mainnet); every fact comes from its $UPGRADE_ENV.toml,
# permanent-values/$UPGRADE_ENV.toml, the output and the chain.
#   1. CTMUpgrade_v34Era.prepare — CREATE2 deployments and factory-dep publication (fork only), writes
#      output/$UPGRADE_ENV/ecosystem.toml
#   2. every factory dep of the L2 upgrade tx is published to the BytecodesSupplier
#   3. the output, decoded with cast and checked against values derived here (the environment's facts below,
#      AllContractsHashes.json, the v34 genesis, v33's committed output), not taken from the generator
#   4. CREATE2 provenance of every deployer transaction
#   5. on the fork, as the real senders (impersonated): the ServerNotifier upgrade, governance stages 0/1/2
#      (with the timer, after its delay), the reference chain's timestamp, its upgrade reverting while batches
#      are in flight, the drain, the upgrade, a test chain, and the L1 state after each step; then v34's L1
#      behaviour: the 15M cap on user L1->L2 transactions (before and after the upgrade), the chain's first v34
#      batches committed, proved and executed (test/foundry/fork/V34EraStageFirstBatch.t.sol, in forge's
#      memory), and the proof-system switches. A reference chain with a pending L2 upgrade (mainnet's 324 right
#      after ZIP-18) can't upgrade yet: its after-upgrade checks move to the test chain.
#
# Needs: foundry (cast/anvil; forge for step 1 and the first-batch test), python3 >= 3.11 (tomllib), and for
# step 1 the Linux CI build artifacts in {system,l1,l2}-contracts/zkout and l1-contracts/out (macOS zksolc
# hashes differ).
# Usage: UPGRADE_ENV=<env> DEPLOYER=<eoa> L1_FORK_URL=<rpc> [FORK_BLOCK=<n>] ./rehearse.sh   (PORT defaults to 8634)
# Only the anvil it starts is stopped (by PID).
# The first-batch test compiles contracts/ into FORK_TEST_OUT (default: a temp dir; never out/, zkout/ or
# cache-forge/, which step 1 reads). FIRST_BATCH_TEST=0 skips it; it is on by default only when running
# standalone with a testnet verifier, which accepts the test's empty proofs.
#
# The generate / deploy pipeline (upgrade.toml in this directory) reuses it:
#   L1_RPC_URL=<fork>  ECOSYSTEM_TOML=<bundle's toml>  — check a fork the bundle was already replayed on
#       (`protocol_ops ecosystem rehearse-upgrade` / `replay-bundle`): no anvil is started and step 1 is
#       skipped. The deployer transactions are read from prepare/ next to ECOSYSTEM_TOML. The first-batch
#       test runs only with FIRST_BATCH_TEST=1.
#   L1_RPC_URL=<chain> [ECOSYSTEM_TOML=<toml>] ./rehearse.sh --published-only — read-only, safe against
#       a real chain: every factory dep is published and every deployed contract has code, then stop. It
#       never starts anvil, prepares or funds; without ECOSYSTEM_TOML it reads the committed output.
# Steps 3–5 refuse any RPC that is not an Anvil fork of the environment's L1.
set -uo pipefail

PUBLISHED_ONLY=0
[ "${1:-}" = "--published-only" ] && PUBLISHED_ONLY=1
[ "$PUBLISHED_ONLY" = "0" ] || [ -n "${L1_RPC_URL:-}" ] || { echo "PUBLICATION CHECK FAILED: --published-only needs L1_RPC_URL"; exit 1; }
# Only the script's own anvil prepares: step 1 would broadcast to L1_RPC_URL.
[ -z "${L1_RPC_URL:-}" ] || [ -n "${ECOSYSTEM_TOML:-}" ] || [ "$PUBLISHED_ONLY" = "1" ] || {
  echo "REHEARSAL FAILED: L1_RPC_URL (it overrides L1_FORK_URL) needs ECOSYSTEM_TOML or --published-only;"\
    "unset it to rehearse on this script's own anvil"
  exit 1
}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(cd "$HERE/../.." && pwd)
S=$(mktemp -d)
PORT=${PORT:-8634}
: "${UPGRADE_ENV:?set UPGRADE_ENV to the environment (stage, testnet3, mainnet)}"
[ -f "$HERE/$UPGRADE_ENV.toml" ] || { echo "REHEARSAL FAILED: no $HERE/$UPGRADE_ENV.toml"; exit 1; }
OUT_REL=/upgrade-envs/v0.34.0-era/output/$UPGRADE_ENV/ecosystem.toml
OUT=${ECOSYSTEM_TOML:-$WT$OUT_REL}
BROADCAST_LOG=
FAILED=0
SKIPPED=0
# Checks run on the test chain because the reference chain can't upgrade yet (a pending L2 upgrade).
MOVED=0
python3 -c 'import tomllib' 2>/dev/null || { echo "REHEARSAL FAILED: needs python3 >= 3.11 (tomllib)"; exit 1; }
export OUT S HERE WT

fail() { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
# While MOVING=1, every check counts as moved to the test chain (see the reference chain's upgrade in step 5).
moved() { [ "${MOVING:-0}" = "1" ] && MOVED=$((MOVED + 1)); return 0; }
chk() { moved; [ "$(echo "$2" | tr A-F a-f)" = "$(echo "$3" | tr A-F a-f)" ] && echo "  OK   $1" || fail "$1: expected $3, got $2"; }
call() { cast call "$@" --rpc-url "$RPC"; }
first() { awk '{print $1}'; }

if [ -n "${L1_RPC_URL:-}" ]; then
  RPC="$L1_RPC_URL"
  # Opt-in here: CI's verify-bundle-handoff has no build, and an RPC may cap the log search.
  FIRST_BATCH_TEST=${FIRST_BATCH_TEST:-0}
  echo "using the chain at L1_RPC_URL, block $(cast block-number --rpc-url "$RPC")"
else
  : "${L1_FORK_URL:?set L1_FORK_URL to an RPC of the environment L1}"
  # Step 1 prepares as this account; it is baked into the bundle, so it must be the one that will broadcast.
  : "${DEPLOYER:?set DEPLOYER to the deployer EOA}"
  RPC=http://127.0.0.1:$PORT
  # Never fund or send to another session's anvil.
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && { echo "REHEARSAL FAILED: port $PORT is in use; set PORT"; exit 1; }
  anvil --fork-url "$L1_FORK_URL" ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} --port "$PORT" \
    --auto-impersonate --disable-block-gas-limit --silent > "$S/anvil_v34.log" 2>&1 &
  ANVIL_PID=$!
  trap 'kill $ANVIL_PID 2>/dev/null' EXIT
  for _ in $(seq 1 60); do
    kill -0 "$ANVIL_PID" 2>/dev/null || break
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
  done
  kill -0 "$ANVIL_PID" 2>/dev/null || { echo "REHEARSAL FAILED: anvil exited (log: $S/anvil_v34.log)"; exit 1; }
  echo "fork block: $(cast block-number --rpc-url "$RPC")"
fi
# The first-batch test searches the chain's history up to here.
START_BLOCK=$(cast block-number --rpc-url "$RPC")
export RPC

# ---------------------------------------------------------------- the environment's facts
# Inputs from $UPGRADE_ENV.toml and permanent-values (not its possibly stale CTM entries), the other addresses
# from the chain before step 1 changes it. Each input the chain also holds is checked against it
# (EIP7702_CHECKER in step 5, against the live MailboxFacet's code). --published-only needs none, and may run
# after stage 1.
if [ "$PUBLISHED_ONLY" = "0" ]; then
  python3 - "$HERE/$UPGRADE_ENV.toml" "$WT/upgrade-envs/permanent-values/$UPGRADE_ENV.toml" <<'PYINPUTS' \
    > "$S/inputs.env" || { echo "REHEARSAL FAILED: cannot read the inputs"; exit 1; }
import re, sys, tomllib
env, permanent = (tomllib.load(open(p, "rb")) for p in sys.argv[1:])
(chain_id,) = env["chain_ids"]  # the checks cover one chain
ADDRESS, NUMBER, WORD, BOOL = r"0x[0-9a-fA-F]{40}", r"[0-9]+", r"0x[0-9a-fA-F]{64}", r"True|False"
# The script's rules for the optional inputs: a fresh FFLONK verifier xor a reused one; a production
# verifier is identified by its codehash.
deploy_fflonk, testnet = env["deploy_verifier_fflonk"], env["testnet_verifier"]
if deploy_fflonk == ("verifier_fflonk" in env) or testnet == ("old_verifier_codehash" in env):
    sys.exit("  inputs: verifier_fflonk / old_verifier_codehash don't match deploy_verifier_fflonk / testnet_verifier")
for name, value, pattern in [
    ("CTM", env["ctm"], ADDRESS),
    ("SUPPLIER", env["bytecodes_supplier"], ADDRESS),
    ("PERMISSIONLESS_VALIDATOR", env["permissionless_validator"], ADDRESS),
    ("CAH", env["chain_asset_handler"], ADDRESS),
    ("ROLLUP_DA_MANAGER", env["rollup_da_manager"], ADDRESS),
    ("EIP7702_CHECKER", env["eip7702_checker"], ADDRESS),
    ("DEPLOY_FFLONK", deploy_fflonk, BOOL),
    # Reused: the input; deployed: empty here, the output's verifier_fflonk_addr (checked by provenance).
    ("FFLONK", env.get("verifier_fflonk", ""), ADDRESS if not deploy_fflonk else ""),
    ("DIAMOND_INIT", env["diamond_init"], ADDRESS),
    ("ERA_CHAIN_ID", env["era_chain_id"], NUMBER),
    ("TESTNET", testnet, BOOL),
    ("OLD_VERIFIER_CODEHASH", env.get("old_verifier_codehash", ""), WORD if not testnet else ""),
    # Empty: no timer.
    ("TIMER_DELAY", env.get("governance_upgrade_timer_initial_delay", ""),
     NUMBER if "governance_upgrade_timer_initial_delay" in env else ""),
    ("OLD", env["old_protocol_version"], NUMBER),
    ("NEW", env["new_protocol_version"], NUMBER),
    ("TS", env["upgrade_timestamp"], NUMBER),
    ("SALT", env["create2_factory_salt"], WORD),
    ("CHAIN_ID", chain_id, NUMBER),
    ("L1_CHAIN_ID", permanent["l1_chain_id"], NUMBER),
    ("FACTORY", permanent["permanent_contracts"]["create2_factory_addr"], ADDRESS),
    ("BRIDGEHUB", permanent["core_contracts"]["bridgehub_proxy_addr"], ADDRESS),
    ("ZK_TOKEN_ASSET_ID", permanent["zk_token_asset_id"], WORD),
]:
    # str() keeps a bool or a float from passing as a number.
    if not re.fullmatch(pattern, str(value)):
        sys.exit(f"  {name}: malformed {value!r}")
    print(f"export {name}={value}")
event = bytes.fromhex(env["current_chain_creation_params_event_data"][2:])
cut_at, deps_at = (int.from_bytes(event[32 * i:32 * i + 32], "big") for i in (4, 6))
print(f"export STORED_CUT=0x{32:064x}{event[cut_at:deps_at].hex()}")
print(f"export STORED_CUT_INIT=0x{event[cut_at + 44:cut_at + 64].hex()}")
PYINPUTS
  # shellcheck disable=SC1091
  . "$S/inputs.env"
  # Mirrors ERA_TEST_CREATE_CHAIN_ID in deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol.
  export TEST_CHAIN_ID=555

  # fact NAME CAST_ARGS… — one read, exported; a failed read, a zero or a non-address stops the run.
  fact() {
    local v
    v=$(cast "${@:2}" --rpc-url "$RPC" 2> "$S/fact.err")
    [[ $v =~ ^0x[0-9a-fA-F]{40}$ && ! $v =~ ^0x0{40}$ ]] && { export "$1=$v"; return; }
    echo "REHEARSAL FAILED: $1 unreadable (${v:-no answer}): cast ${*:2}"
    head -c 300 "$S/fact.err"
    exit 1
  }
  fact PUH call "$CTM" 'owner()(address)'
  fact CTM_PROXY_ADMIN admin "$CTM"
  fact SN call "$CTM" 'serverNotifierAddress()(address)'
  fact SN_PROXY_ADMIN admin "$SN"
  fact ECO_ADMIN call "$BRIDGEHUB" 'admin()(address)'
  fact ECO_ADMIN_OWNER call "$ECO_ADMIN" 'owner()(address)'
  fact VT call "$CTM" 'validatorTimelockPostV29()(address)'
  fact INTEROP_CENTER call "$CTM" 'INTEROP_CENTER()(address)'
  fact L1_ASSET_ROUTER call "$BRIDGEHUB" 'assetRouter()(address)'
  fact CHAIN_REGISTRATION_SENDER call "$BRIDGEHUB" 'chainRegistrationSender()(address)'
  fact GENESIS_UPGRADE call "$CTM" 'l1GenesisUpgrade()(address)'
  fact DIAMOND call "$CTM" 'getZKChain(uint256)(address)' "$CHAIN_ID"
  fact CHAIN_ADMIN call "$CTM" 'getChainAdmin(uint256)(address)' "$CHAIN_ID"
  fact CHAIN_ADMIN_OWNER call "$CHAIN_ADMIN" 'owner()(address)'
  fact OLD_VERIFIER call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$OLD"
  fact LIVE_ADMIN_FACET call "$DIAMOND" 'facetAddress(bytes4)(address)' "$(cast sig 'acceptAdmin()')"

  echo "== The inputs against the chain"
  chk "l1_chain_id = the RPC's chain id" "$(cast chain-id --rpc-url "$RPC")" "$L1_CHAIN_ID"
  chk "ctm = the bridgehub's chainTypeManager($CHAIN_ID)" \
    "$(call "$BRIDGEHUB" 'chainTypeManager(uint256)(address)' "$CHAIN_ID")" "$CTM"
  chk "bridgehub_proxy_addr = the CTM's BRIDGE_HUB()" "$(call "$CTM" 'BRIDGE_HUB()(address)')" "$BRIDGEHUB"
  chk "old_protocol_version = the CTM's protocolVersion()" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$OLD"
  chk "bytecodes_supplier = the CTM's L1_BYTECODES_SUPPLIER()" \
    "$(call "$CTM" 'L1_BYTECODES_SUPPLIER()(address)')" "$SUPPLIER"
  chk "permissionless_validator = the CTM's PERMISSIONLESS_VALIDATOR()" \
    "$(call "$CTM" 'PERMISSIONLESS_VALIDATOR()(address)')" "$PERMISSIONLESS_VALIDATOR"
  chk "chain_asset_handler = the bridgehub's chainAssetHandler()" \
    "$(call "$BRIDGEHUB" 'chainAssetHandler()(address)')" "$CAH"
  if [ "$DEPLOY_FFLONK" = "True" ]; then
    echo "     deploy_verifier_fflonk: the old verifier's FFLONK_VERIFIER() $(call "$OLD_VERIFIER" 'FFLONK_VERIFIER()(address)') is not reused"
  else
    chk "verifier_fflonk = FFLONK_VERIFIER() of the old version's verifier" \
      "$(call "$OLD_VERIFIER" 'FFLONK_VERIFIER()(address)')" "$FFLONK"
  fi
  if [ "$TESTNET" = "True" ]; then
    chk "the old version's verifier is a testnet one" "$(call "$OLD_VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" "true"
  else
    # EraDualVerifier has no IS_TESTNET_VERIFIER(): identified by its code.
    chk "old_verifier_codehash = the old version's verifier's codehash" \
      "$(cast keccak "$(cast code "$OLD_VERIFIER" --rpc-url "$RPC")")" "$OLD_VERIFIER_CODEHASH"
  fi
  chk "rollup_da_manager = ROLLUP_DA_MANAGER() of chain $CHAIN_ID's AdminFacet" \
    "$(call "$LIVE_ADMIN_FACET" 'ROLLUP_DA_MANAGER()(address)')" "$ROLLUP_DA_MANAGER"
  chk "era_chain_id = the asset router's ERA_CHAIN_ID()" \
    "$(call "$L1_ASSET_ROUTER" 'ERA_CHAIN_ID()(uint256)' | first)" "$ERA_CHAIN_ID"
  chk "current_chain_creation_params_event_data: its cut hashes to the CTM's initialCutHash()" \
    "$(cast keccak "$STORED_CUT")" "$(call "$CTM" 'initialCutHash()(bytes32)')"
  chk "diamond_init = that cut's initAddress" "$STORED_CUT_INIT" "$DIAMOND_INIT"
  chk "PUH, the CTM's owner() = the bridgehub's owner()" "$(call "$BRIDGEHUB" 'owner()(address)')" "$PUH"
  chk "ecosystem admin, the bridgehub's admin() = the ServerNotifier ProxyAdmin's owner()" \
    "$(call "$SN_PROXY_ADMIN" 'owner()(address)')" "$ECO_ADMIN"
  [ "$FAILED" = "0" ] || { echo "REHEARSAL FAILED: the inputs differ from the chain"; exit 1; }
  # Standalone, on by default only where the empty-proof test can pass: a testnet verifier.
  if [ -z "${FIRST_BATCH_TEST:-}" ]; then
    [ "$TESTNET" = "True" ] && FIRST_BATCH_TEST=1 || FIRST_BATCH_TEST=0
  fi
fi

# ---------------------------------------------------------------- 1. prepare
if [ -n "${ECOSYSTEM_TOML:-}" ] || [ "$PUBLISHED_ONLY" = "1" ]; then
  echo "using the prepared output at $OUT"
  [ -f "$OUT" ] || { echo "REHEARSAL FAILED: $OUT not found"; exit 1; }
else
  cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  mkdir -p "$(dirname "$OUT")"
  # Never assert against an output left over from an earlier run.
  rm -f "$OUT"
  # Only a broadcast log written by this run counts.
  touch "$S/before-prepare"
  cd "$WT"
  forge script deploy-scripts/upgrade/v34-era/CTMUpgrade_v34Era.s.sol:CTMUpgrade_v34Era \
    --sig 'prepare(string,string)' "/upgrade-envs/v0.34.0-era/$UPGRADE_ENV.toml" "$OUT_REL" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --legacy --slow --ffi \
    > "$S/v34_prepare.log" 2>&1
  PREPARE_EXIT=$?
  echo "prepare exit: $PREPARE_EXIT"; grep -E 'v34:|Error|revert|ONCHAIN EXECUTION' "$S/v34_prepare.log" | tail -8
  if [ "$PREPARE_EXIT" != "0" ] || [ ! -f "$OUT" ]; then
    echo "REHEARSAL FAILED: prepare did not produce an output (log: $S/v34_prepare.log)"
    exit 1
  fi
  BROADCAST_LOG=$(find "$WT/broadcast/CTMUpgrade_v34Era.s.sol" -name '*-latest.json' -newer "$S/before-prepare" 2>/dev/null | head -1)
  [ -n "$BROADCAST_LOG" ] || { echo "REHEARSAL FAILED: prepare wrote no broadcast log"; exit 1; }
fi
export BROADCAST_LOG

# ---------------------------------------------------------------- 2. publication
toml_get() { python3 -c "import tomllib,sys; d=tomllib.load(open('$OUT','rb')); v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }
# Fail closed: an unreadable output, a missing key or an RPC error must not count as published.
python3 -c "import tomllib; [print(h) for h in tomllib.load(open('$OUT','rb'))['contracts_config']['l2_upgrade_tx_factory_deps']]" > "$S/v34_factory_deps.txt" \
  || { echo "REHEARSAL FAILED: cannot read l2_upgrade_tx_factory_deps from $OUT"; exit 1; }
BS=$(toml_get contracts_config.bytecodes_supplier) || { echo "REHEARSAL FAILED: cannot read bytecodes_supplier"; exit 1; }
UNPUB=0; N=0
while read -r h; do
  N=$((N + 1))
  b=$(cast call "$BS" 'publishingBlock(bytes32)(uint256)' "$h" --rpc-url "$RPC" | awk '{print $1}')
  case "$b" in
    '' | *[!0-9]* | 0) UNPUB=$((UNPUB + 1)); echo "  unpublished or unreadable: $h (${b:-no answer})" ;;
  esac
done < "$S/v34_factory_deps.txt"
echo "L2 upgrade tx factory deps: $N, unpublished: $UNPUB (supplier $BS)"
# Each deployed one is the CREATE2 address of a reviewed init code (step 4 checks that on the fork), so code
# there can only be that contract. The FFLONK verifier is deployed (testnet3) or reused; either way it must have
# code. The timer and stage validator exist only where the output lists them.
DEPLOYED_KEYS=(state_transition.admin_facet_addr state_transition.getters_facet_addr
  state_transition.mailbox_facet_addr state_transition.executor_facet_addr state_transition.migrator_facet_addr
  state_transition.committer_facet_addr state_transition.airbender_verifier_addr state_transition.verifier_addr
  state_transition.verifier_fflonk_addr state_transition.default_upgrade_addr
  state_transition.chain_type_manager_implementation_addr state_transition.server_notifier_implementation_addr)
python3 -c "import tomllib; tomllib.load(open('$OUT','rb'))['deployed_addresses']['l1_governance_upgrade_timer']" 2>/dev/null \
  && DEPLOYED_KEYS+=(deployed_addresses.l1_governance_upgrade_timer deployed_addresses.upgrade_stage_validator)
NOCODE=0
for k in "${DEPLOYED_KEYS[@]}"; do
  a=$(toml_get "$k") || a=
  c=$([ -n "$a" ] && cast code "$a" --rpc-url "$RPC")
  case "$c" in '' | 0x) NOCODE=$((NOCODE + 1)); echo "  no code or unreadable: $k ${a:-(missing)}" ;; esac
done
echo "contracts with code to check: ${#DEPLOYED_KEYS[@]}, without code: $NOCODE"
if [ "$PUBLISHED_ONLY" = "1" ]; then
  [ "$N" -gt 0 ] && [ "$UNPUB" = "0" ] && [ "$NOCODE" = "0" ] && { echo "PUBLICATION CHECK PASSED"; exit 0; }
  echo "PUBLICATION CHECK FAILED"; exit 1
fi
[ "$N" -gt 0 ] && [ "$UNPUB" = "0" ] || { echo "REHEARSAL FAILED: factory deps not published"; exit 1; }
[ "$NOCODE" = "0" ] || { echo "REHEARSAL FAILED: deployed contracts without code"; exit 1; }
chk "bytecodes_supplier = the CTM's" "$BS" "$SUPPLIER"

# The rest funds accounts and sends as the real owners: Anvil forks of the environment's L1 only.
CLIENT=$(cast rpc web3_clientVersion --rpc-url "$RPC" | tr -d '"')
case "$CLIENT" in anvil*) ;; *) echo "REHEARSAL FAILED: refusing to send to $CLIENT, not Anvil"; exit 1 ;; esac
[ "$(cast chain-id --rpc-url "$RPC")" = "$L1_CHAIN_ID" ] || { echo "REHEARSAL FAILED: not a fork of chain $L1_CHAIN_ID"; exit 1; }
echo "fork: $CLIENT"

# The reference chain's live selectors, read before anything is sent (the upgrade cut must remove exactly these).
cast call "$DIAMOND" 'facets()' --rpc-url "$RPC" > "$S/live_facets.hex"

# ---------------------------------------------------------------- 3. the output, decoded
# Writes $S/expected.env (values the fork checks compare against), $S/adds.json (the new facets), the
# calls to send ($S/stage{0,1,2}.txt, $S/sn_multicall.txt, $S/test_create_chain.txt).
python3 - <<'PYSTATIC' || fail "decoded output (see above)"
import json, os, subprocess, sys, tomllib
E = os.environ

def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"cast {args[0]} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()

I = lambda x: int(str(x), 0)
CUT = "((address,uint8,bool,bytes4[])[],address,bytes)"
L2TX = "(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes)"
PU = f"({L2TX},bytes32,bytes32,bytes32,address,(bytes32,bytes32,bytes32),bytes,bytes,uint256,uint256)"
PARAMS = f"(address,bytes32,uint64,bytes32,bytes32,{CUT},bytes)"
FDD = "(uint256,uint256,address,bytes32,address,uint256,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,bytes,address,address,address,address,bytes32)"
FD = "(bytes32,address,bool,uint256,bytes)[]"
CALLS = "(address,uint256,bytes)[]"
ZERO = "0x" + "00" * 20
dec = lambda types, data: json.loads(cast("abi-decode", "--json", "--input", f"f({types})", data))[0]
dec_call = lambda sig, data: json.loads(cast("calldata-decode", "--json", sig, data))
enc = lambda types, value: cast("abi-encode", f"f({types})", value)
keccak = lambda data: cast("keccak", data)
sig = lambda s: cast("sig", s)
calldata = lambda s, *args: cast("calldata", s, *args)

def fmt_cut(c):
    cuts = ",".join(f"({f[0]},{I(f[1])},{str(f[2]).lower()},[{','.join(f[3])}])" for f in c[0])
    return f"([{cuts}],{c[1]},{c[2]})"

def fmt_tx(t):
    arr = lambda xs: "[" + ",".join(str(I(x)) for x in xs) + "]"
    return "(" + ",".join([*(str(I(x)) for x in t[:10]), arr(t[10]), t[11], t[12], arr(t[13]), t[14], t[15]]) + ")"

def fmt_calls(calls):
    return "[" + ",".join(f"({c[0]},{I(c[1])},{c[2]})" for c in calls) + "]"

def norm(v):
    if isinstance(v, str):
        return v.lower()
    if isinstance(v, (list, tuple)):
        return [norm(x) for x in v]
    return v

def short(v):
    s = v if isinstance(v, str) else json.dumps(v)
    return s if len(s) <= 160 else f"{s[:80]}…({len(s)} chars)…{s[-40:]}"

failed = 0
def check(name, got, expected):
    global failed
    got, expected = norm(got), norm(expected)
    if got == expected:
        print(f"  OK   {name}")
        return
    failed += 1
    if isinstance(got, list) and isinstance(expected, list) and len(got) == len(expected):
        diff = [(i, short(g), short(e)) for i, (g, e) in enumerate(zip(got, expected)) if g != e]
        print(f"  FAIL {name}: (index, got, expected) {diff}")
    else:
        print(f"  FAIL {name}: expected {short(expected)}, got {short(got)}")

def ok(name, cond, detail=""):
    check(name + (f" ({detail})" if detail and not cond else ""), bool(cond), True)

eco = tomllib.load(open(E["OUT"], "rb"))
# Stage's v0.33.0 output for every environment: it supplies v0.33.0's L2 upgrade-tx force-deployment list, which
# carries no environment data and is the same wherever the chains came from the same v0.33.0 base.
v33 = tomllib.load(open(E["WT"] + "/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml", "rb"))
genesis = json.load(open(E["WT"] + "/../configs/genesis/era/latest.json"))
hashes = json.load(open(E["WT"] + "/../AllContractsHashes.json"))
zk = {e["contractName"]: e["zkBytecodeHash"].lower() for e in hashes if e.get("zkBytecodeHash")}
known_zk = {e["zkBytecodeHash"].lower() for e in hashes if e.get("zkBytecodeHash")}
cc, st = eco["contracts_config"], eco["state_transition"]
boot, aa, evm = genesis["bootloader_hash"], genesis["default_aa_hash"], genesis["evm_emulator_hash"]

print("== Reused addresses in the output")
reused = {"diamond_init_addr": "DIAMOND_INIT", "genesis_upgrade_addr": "GENESIS_UPGRADE",
          "chain_type_manager_proxy": "CTM", "bytecodes_supplier_addr": "SUPPLIER",
          "permissionless_validator_addr": "PERMISSIONLESS_VALIDATOR", "eip7702_checker_addr": "EIP7702_CHECKER"}
if E["DEPLOY_FFLONK"] == "False":
    reused["verifier_fflonk_addr"] = "FFLONK"
check("state_transition: reused addresses = the live ones", [st[k] for k in reused], [E[v] for v in reused.values()])
# The Boojum verifier the new verifier must point at: the reused one, or the deployed one (step 4 checks its
# provenance).
fflonk = st["verifier_fflonk_addr"]
da = eco["deployed_addresses"]
timer_on = E["TIMER_DELAY"] != ""
check("deployed_addresses lists the timer and the stage validator exactly when the input has a delay",
      ["l1_governance_upgrade_timer" in da, "upgrade_stage_validator" in da], [timer_on, timer_on])
timer, validator = da.get("l1_governance_upgrade_timer", ZERO), da.get("upgrade_stage_validator", ZERO)
check("deployed_addresses: CTM ProxyAdmin, ServerNotifier proxy, RollupDAManager",
      [da["transparent_proxy_admin"], da["server_notifier_proxy_addr"], da["l1_rollup_da_manager"]],
      [E["CTM_PROXY_ADMIN"], E["SN"], E["ROLLUP_DA_MANAGER"]])

print("== L2 upgrade transaction and ProposedUpgrade")
cut = dec(CUT, cc["upgrade_cut_data"])
check("upgrade_cut_data re-encodes byte for byte (cast)", enc(CUT, fmt_cut(cut)), cc["upgrade_cut_data"])
init = cut[2]
check("init selector = upgrade(ProposedUpgrade)", init[:10], sig(f"upgrade({PU})"))
p = dec_call(f"upgrade({PU})", init)[0]
tx = p[0]
check("bootloader hash = genesis", p[1], boot)
check("default account hash = genesis (unchanged)", p[2], aa)
check("EVM emulator hash = genesis", p[3], evm)
check("verifier and verifierParams zero", [p[4], p[5]], [ZERO, ["0x" + "00" * 32] * 3])
check("l1ContractsUpgradeCalldata, postUpgradeCalldata empty; upgradeTimestamp 0", [p[6], p[7], I(p[8])], ["0x", "0x", 0])
check("newProtocolVersion = v0.34.0", I(p[9]), I(E["NEW"]))
semver = genesis["protocol_semantic_version"]
check("new_protocol_version = the genesis's protocol_semantic_version", I(E["NEW"]),
      semver["major"] << 64 | semver["minor"] << 32 | semver["patch"])
check("tx: type 254, from 0x8007, to 0x8006, gas 72M, 800 per pubdata, no fees or paymaster, nonce 34, value 0",
      [I(x) for x in tx[:10]], [254, 0x8007, 0x8006, 72_000_000, 800, 0, 0, 0, I(E["NEW"]) >> 32, 0])
check("tx reserved, signature, paymasterInput, reservedDynamic empty", [[I(x) for x in tx[10]], tx[12], tx[14], tx[15]], [[0] * 4, "0x", "0x", "0x"])
fd_sig = f"forceDeployOnAddresses({FD})"
check("tx.data selector = forceDeployOnAddresses", tx[11][:10], sig(fd_sig))
pairs = [(fd[1].lower(), fd[0].lower()) for fd in dec_call(fd_sig, tx[11])[0]]
v33_cut = dec(CUT, v33["contracts_config"]["upgrade_cut_data"])
v33_tx = dec_call(f"upgrade({PU})", v33_cut[2])[0][0]
v33_pairs = [(fd[1].lower(), fd[0].lower()) for fd in dec_call(fd_sig, v33_tx[11])[0]]
replaced = {"0x000000000000000000000000000000000000800a": zk["l1-contracts/L2BaseTokenEra"],
            "0x000000000000000000000000000000000001000c": zk["l1-contracts/SystemContractProxyAdmin"]}
expected_pairs = [(a, replaced.get(a, x)) for a, x in v33_pairs]
check(f"force deployments = v33's 31 with 0x800A and 0x1000c at the current build ({len(pairs)})", pairs, expected_pairs)
ok("no constructor calls, value or input", all(not fd[2] and I(fd[3]) == 0 and fd[4] == "0x" for fd in dec_call(fd_sig, tx[11])[0]))
ok("every force-deployed hash is in AllContractsHashes.json", all(x in known_zk for _, x in pairs))
deps = ["0x%064x" % I(d) for d in tx[13]]
check("factory deps [0..2] = bootloader, default account, EVM emulator", deps[:3], [boot, aa, evm])
core = ["L2Bridgehub", "L2AssetRouter", "L2NativeTokenVault", "L2MessageRoot", "L2MessageVerification", "L2ChainAssetHandler",
        "L2InteropRootStorage", "BaseTokenHolder", "L2AssetTracker", "InteropCenter", "InteropHandler", "GWAssetTracker",
        "TransparentUpgradeableProxy", "BeaconProxy", "L2SharedBridgeLegacy", "BridgedStandardERC20", "DiamondProxy", "ProxyAdmin"]
expected_deps = {boot.lower(), aa.lower(), evm.lower()} | {x for _, x in expected_pairs} | {zk[f"l1-contracts/{n}"] for n in core}
check(f"factory deps = base system + force-deployed + {len(core)} core contracts ({len(deps)})", sorted(set(deps)), sorted(expected_deps))
ok("no duplicate factory deps, at most 64", len(set(deps)) == len(deps) <= 64)
check("factory deps = contracts_config.l2_upgrade_tx_factory_deps", deps, cc["l2_upgrade_tx_factory_deps"])
tx_hash = keccak(enc(L2TX, fmt_tx(tx)))
check("l2_upgrade_tx_hash = keccak(abi.encode(tx))", cc["l2_upgrade_tx_hash"], tx_hash)

print("== Upgrade cut")
removes = [c for c in cut[0] if I(c[1]) == 2]
adds = [c for c in cut[0] if I(c[1]) == 0]
check("cut = Removes then Adds only", [I(c[1]) for c in cut[0]], [2] * len(removes) + [0] * len(adds))
ok("Removes: zero facet, not freezable", all(c[0].lower() == ZERO and not c[2] for c in removes))
live = json.loads(cast("abi-decode", "--json", "f()((address,bytes4[])[])", open(E["S"] + "/live_facets.hex").read().strip()))[0]
live_selectors = sorted(s.lower() for f in live for s in f[1])
check(f"Removes = every selector chain {E['CHAIN_ID']} routes ({len(live_selectors)})", sorted(s.lower() for c in removes for s in c[3]), live_selectors)
facets = {"admin_facet_addr": False, "getters_facet_addr": False, "mailbox_facet_addr": True,
          "executor_facet_addr": True, "migrator_facet_addr": False, "committer_facet_addr": True}
check("Adds = the six new facets, Mailbox/Executor/Committer freezable",
      sorted([c[0].lower(), bool(c[2])] for c in adds), sorted([st[k].lower(), fz] for k, fz in facets.items()))
added = [s.lower() for c in adds for s in c[3]]
ok("no selector added twice", len(added) == len(set(added)))
for s in ["setProofSystemStatus(uint8,bool)", "disabledProofSystems()", "getUserPriorityTxMaxGasLimit()"]:
    ok(f"adds {s}", sig(s) in added)
check("initAddress = EraSettlementLayerV34Upgrade (default_upgrade_addr)", cut[1], st["default_upgrade_addr"])
for c in adds:
    old = max(live, key=lambda f: len({s.lower() for s in f[1]} & {s.lower() for s in c[3]}))
    new_sel, old_sel = {s.lower() for s in c[3]}, {s.lower() for s in old[1]}
    print(f"     {c[0]}: {len(new_sel)} selectors (live {old[0]}: {len(old_sel)}); added {sorted(new_sel - old_sel)}; dropped {sorted(old_sel - new_sel)}")
json.dump([[c[0], bool(c[2]), c[3]] for c in adds], open(E["S"] + "/adds.json", "w"))

print("== New-chain creation params")
params = dec(PARAMS, cc["new_chain_creation_params"])
check("genesisUpgrade = reused L1GenesisUpgrade", params[0], E["GENESIS_UPGRADE"])
check("genesis batch hash, leaf index, commitment, Airbender commitment",
      [params[1], I(params[2]), params[3], params[4]],
      [genesis["genesis_root"], genesis["genesis_rollup_leaf_index"], genesis["genesis_batch_commitment"], genesis["genesis_airbender_batch_commitment"]])
creation_cut = params[5]
check("creation cut initAddress = reused DiamondInit", creation_cut[1], E["DIAMOND_INIT"])
check("creation cut initCalldata = InitializeDataNewChain(genesis hashes)", creation_cut[2], "0x" + boot[2:] + aa[2:] + evm[2:])
check("creation cut facets = the upgrade cut's Adds", creation_cut[0], adds)
d = dec(FDD, params[6])
alias = lambda a: "0x%040x" % ((int(a, 16) + 0x1111000000000000000000000000000000001111) % (1 << 160))
# The chain limit is 100 on stage, testnet3 and mainnet.
check("force deployments: l1ChainId, eraChainId, l1AssetRouter, alias(PUH), chain limit",
      [I(d[0]), I(d[1]), d[2], d[4], I(d[5])], [I(E["L1_CHAIN_ID"]), I(E["ERA_CHAIN_ID"]), E["L1_ASSET_ROUTER"], alias(E["PUH"]), 100])
check("force deployments: l2TokenProxyBytecodeHash = BeaconProxy", d[3], zk["l1-contracts/BeaconProxy"])
infos = ["L2Bridgehub", "L2AssetRouter", "L2NativeTokenVault", "L2MessageRoot", "L2ChainAssetHandler", "InteropCenter",
         "InteropHandler", "L2AssetTracker", "UpgradeableBeaconDeployer", "BaseTokenHolder"]
check("force deployments: bytecode infos = this build's L2 contracts", d[6:16], [zk[f"l1-contracts/{n}"] for n in infos])
check("force deployments: legacy impls, CRS alias, test-only beacon, ZK asset id",
      [d[16], d[17], d[18], d[19], d[20]], [ZERO, ZERO, alias(E["CHAIN_REGISTRATION_SENDER"]), ZERO, E["ZK_TOKEN_ASSET_ID"]])
batch_zero = "(0,%s,%d,0,0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,0x%s,0x%s,0,%s,%s)" % (
    params[1], I(params[2]), "00" * 32, "00" * 32, params[3], params[4])
initial_cut_hash = keccak(enc(CUT, fmt_cut(creation_cut)))
check("contracts_config.new_initial_cut_hash", cc["new_initial_cut_hash"], initial_cut_hash)

print("== Governance calls and the ServerNotifier upgrade")
stages = {s: dec(CALLS, eco["governance_calls"][f"stage{s}_calls"]) for s in range(3)}
PAUSE, UNPAUSE = (E["CAH"], sig("pauseMigration()")), (E["CAH"], sig("unpauseMigration()"))
UPGRADE_CTM = (E["CTM_PROXY_ADMIN"], sig("upgrade(address,address)"))
SET_NEW_VERSION = (E["CTM"], sig(f"setNewVersionUpgrade({CUT},uint256,uint256,uint256,address)"))
SET_CREATION = (E["CTM"], sig(f"setChainCreationParams({PARAMS})"))
check("setChainCreationParams selector", SET_CREATION[1], "0x4958bf4f")
# The timer's calls (stage 1's leading re-pause undoes the unpause of an emergency execution's unfreeze).
T = {"start": (timer, sig("startTimer()")), "deadline": (timer, sig("checkDeadline()")),
     "paused": (validator, sig("checkMigrationsPaused()")), "present": (validator, sig("checkProtocolUpgradePresence()")),
     "unpaused": (validator, sig("checkMigrationsUnpaused()"))}
shapes = {
    0: [PAUSE] + ([T["start"]] if timer_on else []),
    1: ([PAUSE, T["deadline"], T["paused"]] if timer_on else []) + [UPGRADE_CTM, SET_NEW_VERSION, SET_CREATION],
    2: [UNPAUSE] + ([T["present"], T["unpaused"]] if timer_on else []),
}
names = {PAUSE: "pauseMigration", UNPAUSE: "unpauseMigration", UPGRADE_CTM: "ProxyAdmin.upgrade",
         SET_NEW_VERSION: "setNewVersionUpgrade", SET_CREATION: "setChainCreationParams", T["start"]: "startTimer",
         T["deadline"]: "checkDeadline", T["paused"]: "checkMigrationsPaused",
         T["present"]: "checkProtocolUpgradePresence", T["unpaused"]: "checkMigrationsUnpaused"}
for n, shape in shapes.items():
    check(f"stage {n} = [{', '.join(names[c] for c in shape)}], no value",
          [[c[0], c[2][:10], I(c[1])] for c in stages[n]], [[t, sel, 0] for t, sel in shape])

def find(n, call):
    found = [c for c in stages[n] if [c[0].lower(), c[2][:10]] == [call[0].lower(), call[1]]]
    return found[0][2] if len(found) == 1 else "(not exactly once)"

for n, call in [(0, PAUSE), (1, PAUSE), (2, UNPAUSE)] + ([(0, T["start"]), (1, T["deadline"]), (1, T["paused"]),
                                                       (2, T["present"]), (2, T["unpaused"])] if timer_on else []):
    if n == 1 and call == PAUSE and not timer_on:
        continue
    check(f"stage {n} {names[call]}: no arguments", find(n, call), call[1])
check("stage 1 ProxyAdmin.upgrade(CTM, new implementation)", find(1, UPGRADE_CTM),
      calldata("upgrade(address,address)", E["CTM"], st["chain_type_manager_implementation_addr"]))
snvu = dec_call(f"setNewVersionUpgrade({CUT},uint256,uint256,uint256,address)", find(1, SET_NEW_VERSION))
check("stage 1 setNewVersionUpgrade(cut, v0.33.0, no deadline, v0.34.0, new verifier)",
      [enc(CUT, fmt_cut(snvu[0])), I(snvu[1]), I(snvu[2]), I(snvu[3]), snvu[4]],
      [cc["upgrade_cut_data"], I(E["OLD"]), (1 << 256) - 1, I(E["NEW"]), st["verifier_addr"]])
check("stage 1 setChainCreationParams(new params)", find(1, SET_CREATION), "0x4958bf4f" + cc["new_chain_creation_params"][2:])
upgrade_index = [[c[0].lower(), c[2][:10]] for c in stages[1]].index([UPGRADE_CTM[0].lower(), UPGRADE_CTM[1]])
admin = eco["ctm_admin_calls"]
check("ctm_admin_calls: chain_admin, chain_admin_owner", [admin["chain_admin"], admin["chain_admin_owner"]], [E["ECO_ADMIN"], E["ECO_ADMIN_OWNER"]])
sn_calls = dec(CALLS, admin["server_notifier_upgrade"])
check("server_notifier_upgrade = [ServerNotifier ProxyAdmin.upgrade(ServerNotifier, new implementation)]",
      [[c[0], I(c[1]), c[2]] for c in sn_calls],
      [[E["SN_PROXY_ADMIN"], 0, calldata("upgrade(address,address)", E["SN"], st["server_notifier_implementation_addr"])]])

print(f"== Chain {E['CHAIN_ID']} calls (raw calldata its ChainAdmin's owner sends to the ChainAdmin)")
entry = eco["chain_upgrades"][E["CHAIN_ID"]]
check("chain, chain_admin, chain_admin_owner", [entry["chain"], entry["chain_admin"], entry["chain_admin_owner"]],
      [E["DIAMOND"], E["CHAIN_ADMIN"], E["CHAIN_ADMIN_OWNER"]])
multicall = "multicall((address,uint256,bytes)[],bool)"
inner = calldata(f"upgradeChainFromVersion(address,uint256,{CUT})", E["DIAMOND"], E["OLD"], fmt_cut(cut))
check("chain_admin_calldata = multicall([diamond.upgradeChainFromVersion(diamond, v0.33.0, cut)], true)",
      entry["chain_admin_calldata"], calldata(multicall, f"[({E['DIAMOND']},0,{inner})]", "true"))
check(f"set_upgrade_timestamp_calldata = ChainAdmin.setUpgradeTimestamp(v0.34.0, {E['TS']}), sent directly (onlyOwner)",
      entry["set_upgrade_timestamp_calldata"], calldata("setUpgradeTimestamp(uint256,uint256)", E["NEW"], E["TS"]))
notify = calldata("setUpgradeTimestamp(uint256,uint256)", E["CHAIN_ID"], E["TS"])
check(f"server_notifier_timestamp_calldata = multicall([ServerNotifier.setUpgradeTimestamp({E['CHAIN_ID']}, {E['TS']})], true)",
      entry["server_notifier_timestamp_calldata"], calldata(multicall, f"[({E['SN']},0,{notify})]", "true"))
test = eco["test_upgrade_calls"]
check("test_upgrade_chain_era = the multicall's inner call, from the ChainAdmin",
      [test["test_upgrade_chain_era"], test["test_upgrade_chain_era_caller"]],
      [enc(CALLS, f"[({E['DIAMOND']},0,{inner})]"), E["CHAIN_ADMIN"]])
create = dec(CALLS, test["test_create_chain_era"])
check("test_create_chain_era = one createNewChain(555, …) call to the bridgehub, from the bridgehub admin",
      [[c[0], I(c[1]), c[2][:10], I("0x" + c[2][10:74])] for c in create] + [test["test_create_chain_era_caller"]],
      [[E["BRIDGEHUB"], 0, sig("createNewChain(uint256,address,bytes32,uint256,address,bytes,bytes[])"), I(E["TEST_CHAIN_ID"])], E["ECO_ADMIN"]])

# Hand-off to the fork checks.
with open(E["S"] + "/expected.env", "w") as f:
    for k, v in {
        "EXP_L2_TX_HASH": tx_hash, "EXP_UPGRADE_CUT_HASH": keccak(cc["upgrade_cut_data"]),
        "EXP_INITIAL_CUT_HASH": initial_cut_hash, "EXP_FDD_HASH": keccak(enc("bytes", params[6])),
        "EXP_BATCH_ZERO": keccak(enc("(uint64,bytes32,uint64,uint256,bytes32,bytes32,bytes32,uint256,bytes32,bytes32)", batch_zero)),
        "BOOT": boot, "AA": aa, "EVM": evm, "VK0": genesis["prover"]["fflonk_snark_wrapper_vk_hash"],
        "VK2": genesis["prover"]["airbender_snark_wrapper_vk_hash"], "VERIFIER": st["verifier_addr"],
        "AIRBENDER_VERIFIER": st["airbender_verifier_addr"], "NEW_CTM_IMPL": st["chain_type_manager_implementation_addr"],
        "NEW_SN_IMPL": st["server_notifier_implementation_addr"], "UPGRADE_CALLDATA": entry["chain_admin_calldata"],
        "SET_TS_CALLDATA": entry["set_upgrade_timestamp_calldata"], "SN_TS_CALLDATA": entry["server_notifier_timestamp_calldata"],
        "EXP_FFLONK": fflonk, "TIMER": timer, "STAGE_VALIDATOR": validator, "S1_UPGRADE_INDEX": upgrade_index,
    }.items():
        f.write(f"{k}={v}\n")
for s in range(3):
    open(E["S"] + f"/stage{s}.txt", "w").write("".join(f"{c[0]} {I(c[1])} {c[2]}\n" for c in stages[s]))
open(E["S"] + "/sn_multicall.txt", "w").write(calldata(multicall, fmt_calls(sn_calls), "true"))
open(E["S"] + "/test_create_chain.txt", "w").write(f"{create[0][0]} {create[0][2]}\n")
sys.exit(1 if failed else 0)
PYSTATIC
# shellcheck disable=SC1091
. "$S/expected.env" || { echo "REHEARSAL FAILED: the decoded-output step wrote no expectations"; exit 1; }

# ---------------------------------------------------------------- 4. CREATE2 provenance
echo "== CREATE2 provenance (salt, init code = reviewed bytecode + constructor args, nothing else)"
python3 - <<'PYPROVENANCE' || fail "CREATE2 provenance (see above)"
import json, os, subprocess, tomllib
E = os.environ

def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"cast {args[0]} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()

failed = 0
def ok(name, cond, detail=""):
    global failed
    print(f"  {'OK  ' if cond else 'FAIL'} {name}{'' if cond or not detail else ': ' + detail}")
    failed += not cond

eco = tomllib.load(open(E["OUT"], "rb"))
evm = {e["contractName"]: e["evmBytecodeHash"].lower() for e in json.load(open(E["WT"] + "/../AllContractsHashes.json")) if e.get("evmBytecodeHash")}
st, da, salt = eco["state_transition"], eco["deployed_addresses"], E["SALT"].lower()
ok("contracts.create2_factory_addr, create2_factory_salt = the env's", [eco["contracts"]["create2_factory_addr"].lower(), eco["contracts"]["create2_factory_salt"].lower()] == [E["FACTORY"].lower(), salt])

# Deployer transactions: this run's forge broadcast log if it prepared, else the bundle's Safe files next to
# ECOSYSTEM_TOML. A prepare/ an earlier run left next to the committed output doesn't count.
txs, prepare = [], os.path.join(os.path.dirname(E["OUT"]), "prepare")
if E.get("BROADCAST_LOG"):
    log = json.load(open(E["BROADCAST_LOG"]))
    # Forge CREATE2-deploys the script's linked deploy-scripts/ libraries; protocol_ops drops those deploys
    # from the deploy bundle (common/forge/cast_transactions.rs), so they never reach the real chain.
    script_libs = {lib.rsplit(":", 1)[1].lower() for lib in log.get("libraries", []) if lib.startswith("deploy-scripts/")}
    for t in log["transactions"]:
        if t.get("transactionType") == "CREATE2" and (t.get("contractAddress") or "").lower() in script_libs:
            print(f"     skipped: forge's deploy of script library {t.get('contractName')} at {t['contractAddress']} (not in the deploy bundle)")
            continue
        t = t["transaction"]
        txs.append(((t.get("to") or "").lower(), (t.get("input") or t.get("data") or "0x").lower(), int(str(t.get("value") or "0x0"), 16)))
    source = E["BROADCAST_LOG"]
elif os.path.isfile(prepare + "/manifest.json"):
    for b in sorted(json.load(open(prepare + "/manifest.json"))["bundles"], key=lambda b: b["index"]):
        txs += [(t["to"].lower(), t["data"].lower(), int(str(t.get("value") or "0"), 0)) for t in json.load(open(f"{prepare}/{b['file']}"))["transactions"]]
    source = prepare
else:
    raise SystemExit("  FAIL no deployer transactions: no prepare/manifest.json next to ECOSYSTEM_TOML and no broadcast log")
print(f"     {len(txs)} deployer transactions from {source}")

# Constructor arguments, from the environment's facts; the verifier's are the FFLONK verifier (reused, or deployed
# and checked here) and the Plonk verifier's own CREATE2 address, itself checked here. The testnet flag picks the
# Mailbox and Migrator time windows and the verifier contract.
enc = lambda types, *v: cast("abi-encode", f"f({types})", *v)[2:]
testnet = E["TESTNET"].lower()
verifier_name = "EraMultiProofTestnetVerifier" if testnet == "true" else "EraMultiProofVerifier"
expected = {
    "AdminFacet": ("state_transition", "admin_facet_addr", enc("uint256,address", E["L1_CHAIN_ID"], E["ROLLUP_DA_MANAGER"])),
    "GettersFacet": ("state_transition", "getters_facet_addr", ""),
    "MailboxFacet": ("state_transition", "mailbox_facet_addr", enc("uint256,uint256,address,address,bool", E["ERA_CHAIN_ID"], E["L1_CHAIN_ID"], E["CAH"], E["EIP7702_CHECKER"], testnet)),
    "ExecutorFacet": ("state_transition", "executor_facet_addr", enc("uint256", E["L1_CHAIN_ID"])),
    "MigratorFacet": ("state_transition", "migrator_facet_addr", enc("uint256,bool", E["L1_CHAIN_ID"], testnet)),
    "CommitterFacet": ("state_transition", "committer_facet_addr", enc("uint256", E["L1_CHAIN_ID"])),
    "AirbenderVerifierPlonk": ("state_transition", "airbender_verifier_addr", ""),
    verifier_name: ("state_transition", "verifier_addr", enc("address,address", st["verifier_fflonk_addr"], st["airbender_verifier_addr"])),
    "EraSettlementLayerV34Upgrade": ("state_transition", "default_upgrade_addr", ""),
    "EraChainTypeManager": ("state_transition", "chain_type_manager_implementation_addr", enc("address,address,address,address", E["BRIDGEHUB"], E["INTEROP_CENTER"], E["SUPPLIER"], E["PERMISSIONLESS_VALIDATOR"])),
    "ServerNotifier": ("state_transition", "server_notifier_implementation_addr", ""),
}
if E["DEPLOY_FFLONK"] == "True":
    expected["EraVerifierFflonk"] = ("state_transition", "verifier_fflonk_addr", "")
if E["TIMER_DELAY"]:
    # DefaultCTMUpgrade.getCreationCalldata: delay, 2 weeks of extension, governance and owner both the PUH.
    expected["GovernanceUpgradeTimer"] = ("deployed_addresses", "l1_governance_upgrade_timer",
                                          enc("uint256,uint256,address,address", E["TIMER_DELAY"], str(14 * 24 * 3600), E["PUH"], E["PUH"]))
    expected["UpgradeStageValidator"] = ("deployed_addresses", "upgrade_stage_validator", enc("address,uint256", E["CTM"], E["NEW"]))
print(f"     expected deployments: {len(expected)} (11, plus EraVerifierFflonk if deployed, plus the timer and validator)")
publish = {cast("sig", "publishEraBytecodes(bytes[])"), cast("sig", "publishEraBytecode(bytes)")}
matched, published = {}, 0
for to, data, value in txs:
    ok(f"no value sent to {to}", value == 0)
    if to == E["SUPPLIER"].lower() and data[:10] in publish:
        published += 1
        continue
    if to != E["FACTORY"].lower():
        ok(f"unexpected deployer transaction to {to} ({data[:10]})", False)
        continue
    tx_salt, init = "0x" + data[2:66], data[66:]
    address = "0x" + cast("keccak", "0xff" + E["FACTORY"][2:].lower() + tx_salt[2:] + cast("keccak", "0x" + init)[2:])[-40:]
    prefix_hashes, found = {}, None
    for name, (_, _, args) in expected.items():
        if name in matched or not init.endswith(args):
            continue
        if len(args) not in prefix_hashes:
            prefix_hashes[len(args)] = cast("keccak", "0x" + init[: len(init) - len(args)])
        if prefix_hashes[len(args)] == evm.get(f"l1-contracts/{name}"):
            found = name
            break
    if not found:
        ok(f"deployment at {address} is a reviewed contract with the expected constructor args", False, f"{len(init) // 2} bytes of init code")
        continue
    table, key, _ = expected[found]
    matched[found] = address
    ok(f"{found}: salt = the env's, address = {table}.{key}, code on the fork",
       tx_salt == salt and address == eco[table].get(key, "").lower() and cast("code", address, "--rpc-url", E["RPC"]) != "0x")
missing = [n for n in expected if n not in matched]
ok(f"all {len(expected)} expected contracts deployed exactly once", not missing, f"missing {missing}")
print(f"     BytecodesSupplier publication transactions: {published} (already-published deps are skipped)")
raise SystemExit(1 if failed else 0)
PYPROVENANCE

# ---------------------------------------------------------------- 5. the fork flow
# send FROM TO DATA LABEL [VALUE [GAS_PRICE]] — impersonated; cast waits for the receipt, kept in $S/receipt.json.
send() {
  moved
  cast send --unlocked --from "$1" "$2" "$3" ${5:+--value "$5"} ${6:+--gas-price "$6"} --rpc-url "$RPC" --json 2> "$S/send.err" | grep '^{' | tail -1 > "$S/receipt.json"
  st=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$S/receipt.json" 2>/dev/null)
  [ "$st" = "0x1" ] && echo "  OK   $4" || fail "$4 (status ${st:-none}: $(head -c 300 "$S/send.err"))"
}
# calls LABEL FROM TO DATA [VALUE] — eth_call must succeed. No fee fields: it runs at gas price 0.
calls() {
  moved
  out=$(cast call --from "$2" "$3" "$4" ${5:+--value "$5"} --rpc-url "$RPC" 2>&1) && echo "  OK   $1" || fail "$1: $(echo "$out" | tail -1 | head -c 200)"
}
# reverts LABEL FROM TO DATA [ERROR_SIGNATURE [VALUE]] — eth_call must revert, with that error when given.
reverts() {
  moved
  out=$(cast call --from "$2" "$3" "$4" ${6:+--value "$6"} --rpc-url "$RPC" 2>&1) && { fail "$1: did not revert"; return; }
  echo "$out" | grep -qi revert || { fail "$1: the call failed without a revert: $(echo "$out" | tail -1 | head -c 200)"; return; }
  if [ -n "${5:-}" ]; then
    # cast prints the error's selector, or its name when it can decode it.
    sel=$(cast sig "$5")
    echo "$out" | grep -qiE "${sel#0x}|${5%%(*}" && echo "  OK   $1" || fail "$1: reverted with $(echo "$out" | tail -1 | head -c 200)"
  else
    echo "  OK   $1"
  fi
}
# emitted LABEL ADDRESS EVENT_SIGNATURE TOPICS DATA — $S/receipt.json holds exactly one such log. TOPICS: its
# leading indexed arguments, space-separated numbers, or - for none; DATA: its exact (lowercase) hex data, or - for any.
emitted() {
  moved
  python3 - "$S/receipt.json" "$2" "$(cast keccak "$3")" "$4" "$5" <<'PYEMITTED' && echo "  OK   $1" || fail "$1"
import json, sys
receipt, address, topic0, topics, data = sys.argv[1:]
# An empty TOPICS is an unread value, not "none".
if not topics.strip():
    sys.exit("     no topics given")
want = [] if topics == "-" else [int(t, 0) for t in topics.split()]
try:
    logs = json.load(open(receipt))["logs"]
except (OSError, ValueError, KeyError):
    sys.exit("     no receipt")
logs = [l for l in logs if l["address"].lower() == address.lower() and l["topics"][:1] == [topic0]]
sys.exit(0 if len(logs) == 1 and [int(t, 16) for t in logs[0]["topics"][1:1 + len(want)]] == want
         and data in ("-", logs[0]["data"].lower()) else 1)
PYEMITTED
}
for a in "$PUH" "$ECO_ADMIN" "$ECO_ADMIN_OWNER" "$CHAIN_ADMIN_OWNER"; do
  cast rpc anvil_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
done

# Read before the upgrade: v34 must keep the limit, and a pending L2 upgrade blocks the chain's v34 upgrade.
B_PRIORITY_LIMIT=$(call "$DIAMOND" 'getPriorityTxMaxGasLimit()(uint256)' | first)
PENDING_L2_UPGRADE=$(call "$DIAMOND" 'getL2SystemContractsUpgradeTxHash()(bytes32)')
echo "     chain $CHAIN_ID: priorityTxMaxGasLimit $B_PRIORITY_LIMIT, pending L2 upgrade tx $PENDING_L2_UPGRADE"
B_OWNER=$(call "$CTM" 'owner()(address)'); B_ADMIN=$(call "$CTM" 'admin()(address)')
B_SN=$(call "$CTM" 'serverNotifierAddress()(address)'); B_VT=$(call "$CTM" 'validatorTimelockPostV29()(address)')
B_CUT=$(call "$CTM" 'initialCutHash()(bytes32)'); B_CHAIN=$(call "$CTM" 'getZKChain(uint256)(address)' "$CHAIN_ID")
SN_OWNER=$(call "$SN" 'owner()(address)'); SN_CTM=$(call "$SN" 'chainTypeManager()(address)')

echo "== ServerNotifier upgrade, sent by the ecosystem admin's owner"
send "$ECO_ADMIN_OWNER" "$ECO_ADMIN" "$(cat "$S/sn_multicall.txt")" "ecosystem admin multicall(server_notifier_upgrade)"
chk "ServerNotifier implementation" "$(cast implementation "$SN" --rpc-url "$RPC")" "$NEW_SN_IMPL"
chk "ServerNotifier owner unchanged" "$(call "$SN" 'owner()(address)')" "$SN_OWNER"
chk "ServerNotifier chainTypeManager unchanged" "$(call "$SN" 'chainTypeManager()(address)')" "$SN_CTM"
reverts "ServerNotifier proxy: initialize reverts" "$PUH" "$SN" "$(cast calldata 'initialize(address)' "$PUH")"
reverts "ServerNotifier implementation: initialize reverts" "$PUH" "$NEW_SN_IMPL" "$(cast calldata 'initialize(address)' "$PUH")"

if [ -n "$TIMER_DELAY" ]; then
  echo "== The governance timer and stage validator, as deployed"
  chk "timer INITIAL_DELAY = governance_upgrade_timer_initial_delay" "$(call "$TIMER" 'INITIAL_DELAY()(uint256)' | first)" "$TIMER_DELAY"
  chk "timer MAX_ADDITIONAL_DELAY = 2 weeks" "$(call "$TIMER" 'MAX_ADDITIONAL_DELAY()(uint256)' | first)" 1209600
  chk "timer TIMER_GOVERNANCE = the PUH (sends the stages)" "$(call "$TIMER" 'TIMER_GOVERNANCE()(address)')" "$PUH"
  chk "timer owner = the PUH" "$(call "$TIMER" 'owner()(address)')" "$PUH"
  chk "timer not started" "$(call "$TIMER" 'deadline()(uint256)' | first)" 0
  chk "stage validator CHAIN_TYPE_MANAGER = the CTM" "$(call "$STAGE_VALIDATOR" 'CHAIN_TYPE_MANAGER()(address)')" "$CTM"
  chk "stage validator NEW_PROTOCOL_VERSION = v0.34.0" "$(call "$STAGE_VALIDATOR" 'NEW_PROTOCOL_VERSION()(uint256)' | first)" "$NEW"
fi

echo "== Stage 0 and the CTM proxy upgrade, sent as the CTM owner (PUH)"
while read -r target value data; do send "$PUH" "$target" "$data" "stage 0 ${data:0:10} -> $target"; done < "$S/stage0.txt"
chk "migrations paused" "$(call "$CAH" 'migrationPaused()(bool)')" "true"
if [ -n "$TIMER_DELAY" ]; then
  STARTED=$(cast block latest --field timestamp --rpc-url "$RPC")
  chk "timer deadline = stage 0's block time + delay" "$(call "$TIMER" 'deadline()(uint256)' | first)" "$((STARTED + TIMER_DELAY))"
  reverts "stage 1 before the delay: checkDeadline reverts with DeadlineNotYetPassed" "$PUH" "$TIMER" \
    "$(cast calldata 'checkDeadline()')" 'DeadlineNotYetPassed()'
  # An emergency execution unfreezes before a proposal's calls, which unpauses migrations; stage 1's leading
  # re-pause must restore it.
  send "$PUH" "$CAH" "$(cast calldata 'unpauseMigration()')" "unpauseMigration() as the PUH (emulates an unfreeze)"
  cast rpc evm_increaseTime "$TIMER_DELAY" --rpc-url "$RPC" >/dev/null && cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  echo "     advanced the fork's time by $TIMER_DELAY s"
fi
# Stage 1 up to and including the CTM proxy upgrade, then the CTM's state on the new implementation.
head -n "$S1_UPGRADE_INDEX" "$S/stage1.txt" > "$S/stage1_before.txt"
while read -r target value data; do send "$PUH" "$target" "$data" "stage 1 ${data:0:10} -> $target"; done < "$S/stage1_before.txt"
read -r target value data < <(sed -n "$((S1_UPGRADE_INDEX + 1))p" "$S/stage1.txt")
send "$PUH" "$target" "$data" "stage 1 ProxyAdmin.upgrade(CTM)"
chk "CTM implementation" "$(cast implementation "$CTM" --rpc-url "$RPC")" "$NEW_CTM_IMPL"
chk "CTM owner unchanged" "$(call "$CTM" 'owner()(address)')" "$B_OWNER"
chk "CTM admin unchanged" "$(call "$CTM" 'admin()(address)')" "$B_ADMIN"
chk "CTM serverNotifierAddress unchanged" "$(call "$CTM" 'serverNotifierAddress()(address)')" "$B_SN"
chk "CTM validatorTimelockPostV29 unchanged" "$(call "$CTM" 'validatorTimelockPostV29()(address)')" "$B_VT"
chk "CTM initialCutHash unchanged" "$(call "$CTM" 'initialCutHash()(bytes32)')" "$B_CUT"
chk "CTM getZKChain($CHAIN_ID) unchanged" "$(call "$CTM" 'getZKChain(uint256)(address)' "$CHAIN_ID")" "$B_CHAIN"
CUT_T='((address,uint8,bool,bytes4[])[],address,bytes)'
CTM_INIT=$(cast calldata "initialize((address,address,(address,bytes32,uint64,bytes32,bytes32,$CUT_T,bytes),uint256,address,address))" \
  "($PUH,$VT,($GENESIS_UPGRADE,0x$(printf '0%.0s' {1..64}),1,0x$(printf '0%.0s' {1..64}),0x$(printf '0%.0s' {1..64}),([],0x0000000000000000000000000000000000000000,0x),0x),$NEW,$VERIFIER,$SN)")
reverts "CTM proxy: initialize reverts" "$PUH" "$CTM" "$CTM_INIT"
reverts "CTM implementation: initialize reverts" "$PUH" "$NEW_CTM_IMPL" "$CTM_INIT"

echo "== Stages 1 (rest) and 2, as the PUH"
while read -r target value data; do send "$PUH" "$target" "$data" "stage 1 ${data:0:10} -> $target"; done < <(tail -n +$((S1_UPGRADE_INDEX + 2)) "$S/stage1.txt")
while read -r target value data; do send "$PUH" "$target" "$data" "stage 2 ${data:0:10} -> $target"; done < "$S/stage2.txt"

echo "== CTM state after the governance stages"
chk "protocolVersion = v0.34.0" "$(call "$CTM" 'protocolVersion()(uint256)' | first)" "$NEW"
chk "protocolVersionVerifier(v0.34.0) = new verifier" "$(call "$CTM" 'protocolVersionVerifier(uint256)(address)' "$NEW")" "$VERIFIER"
chk "verifier IS_TESTNET_VERIFIER = testnet_verifier" "$(call "$VERIFIER" 'IS_TESTNET_VERIFIER()(bool)')" "$(echo "$TESTNET" | tr A-Z a-z)"
chk "verifier BOOJUM_VERIFIER = the FFLONK verifier (verifier_fflonk_addr)" "$(call "$VERIFIER" 'BOOJUM_VERIFIER()(address)')" "$EXP_FFLONK"
chk "verifier AIRBENDER_VERIFIER = new Plonk" "$(call "$VERIFIER" 'AIRBENDER_VERIFIER()(address)')" "$AIRBENDER_VERIFIER"
chk "verifier verificationKeyHash(0) = genesis FFLONK VK" "$(call "$VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 0)" "$VK0"
chk "verifier verificationKeyHash(2) = genesis Airbender VK" "$(call "$VERIFIER" 'verificationKeyHash(uint256)(bytes32)' 2)" "$VK2"
echo "     new verifier verificationKeyHash() (no argument, what the node stores): $(call "$VERIFIER" 'verificationKeyHash()(bytes32)')"
chk "upgradeCutHash(v0.33.0) = keccak(upgrade_cut_data)" "$(call "$CTM" 'upgradeCutHash(uint256)(bytes32)' "$OLD")" "$EXP_UPGRADE_CUT_HASH"
chk "contracts_config.upgrade_cut_hash" "$(toml_get contracts_config.upgrade_cut_hash)" "$EXP_UPGRADE_CUT_HASH"
chk "initialCutHash = keccak(new creation cut)" "$(call "$CTM" 'initialCutHash()(bytes32)')" "$EXP_INITIAL_CUT_HASH"
chk "initialForceDeploymentHash = keccak(abi.encode(new data))" "$(call "$CTM" 'initialForceDeploymentHash()(bytes32)')" "$EXP_FDD_HASH"
chk "l1GenesisUpgrade" "$(call "$CTM" 'l1GenesisUpgrade()(address)')" "$GENESIS_UPGRADE"
chk "storedBatchZero = StoredBatchInfo(genesis, both commitments)" "$(call "$CTM" 'storedBatchZero()(bytes32)')" "$EXP_BATCH_ZERO"
chk "migrations unpaused" "$(call "$CAH" 'migrationPaused()(bool)')" "false"
for x in "$CTM" "$NEW_CTM_IMPL" "$SN" "$NEW_SN_IMPL"; do
  chk "pendingOwner = 0 on $x" "$(call "$x" 'pendingOwner()(address)')" "0x0000000000000000000000000000000000000000"
done

echo "== Chain $CHAIN_ID's upgrade timestamp, sent by the ChainAdmin's owner"
send "$CHAIN_ADMIN_OWNER" "$CHAIN_ADMIN" "$SET_TS_CALLDATA" "set_upgrade_timestamp_calldata -> ChainAdmin"
send "$CHAIN_ADMIN_OWNER" "$CHAIN_ADMIN" "$SN_TS_CALLDATA" "server_notifier_timestamp_calldata -> ChainAdmin"
python3 - "$S/receipt.json" "$(cast keccak 'UpgradeTimestampUpdated(uint256,uint256,uint256)')" <<'PYLOG' && echo "  OK   UpgradeTimestampUpdated($CHAIN_ID, v0.33.0, $TS) emitted by the ServerNotifier" || fail "UpgradeTimestampUpdated($CHAIN_ID, v0.33.0, $TS) not emitted"
import json, os, sys
logs = [l for l in json.load(open(sys.argv[1]))["logs"] if l["address"].lower() == os.environ["SN"].lower() and l["topics"][0] == sys.argv[2]]
sys.exit(0 if len(logs) == 1 and [int(t, 16) for t in logs[0]["topics"][1:]] == [int(os.environ["CHAIN_ID"]), int(os.environ["OLD"])]
         and int(logs[0]["data"], 16) == int(os.environ["TS"]) else 1)
PYLOG
chk "ServerNotifier protocolVersionToUpgradeTimestamp($CHAIN_ID, v0.33.0)" "$(call "$SN" 'protocolVersionToUpgradeTimestamp(uint256,uint256)(uint256)' "$CHAIN_ID" "$OLD")" "$TS"
chk "ChainAdmin protocolVersionToUpgradeTimestamp(v0.34.0)" "$(call "$CHAIN_ADMIN" 'protocolVersionToUpgradeTimestamp(uint256)(uint256)' "$NEW")" "$TS"

echo "== Negative: chain $CHAIN_ID's upgrade reverts while batches are in flight"
counts() { echo "$(call "$DIAMOND" 'getTotalBatchesCommitted()(uint256)' | first) $(call "$DIAMOND" 'getTotalBatchesVerified()(uint256)' | first) $(call "$DIAMOND" 'getTotalBatchesExecuted()(uint256)' | first)"; }
read -r COMMITTED VERIFIED EXECUTED <<< "$(counts)"
echo "     committed / verified / executed: $COMMITTED / $VERIFIED / $EXECUTED"
if [ "$COMMITTED" != "$EXECUTED" ]; then
  reverts "upgrade reverts with NotAllBatchesExecuted" "$CHAIN_ADMIN_OWNER" "$CHAIN_ADMIN" "$UPGRADE_CALLDATA" "NotAllBatchesExecuted()"
else
  echo "  SKIP upgrade reverts with NotAllBatchesExecuted (chain $CHAIN_ID is idle: nothing in flight)"; SKIPPED=$((SKIPPED + 1))
fi

echo "== Drain chain $CHAIN_ID: revert the unexecuted batches through the ValidatorTimelock"
ROLE=$(cast keccak REVERTER_ROLE)
REVERTER=
for i in $(seq 0 $(($(call "$VT" 'getRoleMemberCount(address,bytes32)(uint256)' "$DIAMOND" "$ROLE" | first) - 1))); do
  m=$(call "$VT" 'getRoleMember(address,bytes32,uint256)(address)' "$DIAMOND" "$ROLE" "$i")
  [ "$(echo "$m" | tr A-F a-f)" != "$(echo "$VT" | tr A-F a-f)" ] && { REVERTER=$m; break; }
done
echo "     REVERTER_ROLE holder used: ${REVERTER:-none}"
if [ "$COMMITTED" = "$EXECUTED" ]; then
  echo "     nothing to revert"
elif [ -n "$REVERTER" ]; then
  cast rpc anvil_setBalance "$REVERTER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  send "$REVERTER" "$VT" "$(cast calldata 'revertBatchesSharedBridge(address,uint256)' "$DIAMOND" "$EXECUTED")" "revertBatchesSharedBridge($CHAIN_ID, $EXECUTED)"
else
  fail "no REVERTER_ROLE holder"
fi
read -r COMMITTED VERIFIED EXECUTED <<< "$(counts)"
[ "$COMMITTED" = "$EXECUTED" ] && [ "$VERIFIED" = "$EXECUTED" ] && echo "  OK   committed == verified == executed ($EXECUTED)" || fail "not drained: $COMMITTED / $VERIFIED / $EXECUTED"

# chain_state LABEL CHAIN — the post-upgrade state of a chain on v0.34.0.
chain_state() {
  chk "$1 protocol version = v0.34.0" "$(call "$2" 'getProtocolVersion()(uint256)' | first)" "$NEW"
  chk "$1 bootloader = new" "$(call "$2" 'getL2BootloaderBytecodeHash()(bytes32)')" "$BOOT"
  chk "$1 default account = unchanged" "$(call "$2" 'getL2DefaultAccountBytecodeHash()(bytes32)')" "$AA"
  chk "$1 EVM emulator = new" "$(call "$2" 'getL2EvmEmulatorBytecodeHash()(bytes32)')" "$EVM"
  chk "$1 verifier = new multi-proof verifier" "$(call "$2" 'getVerifier()(address)')" "$VERIFIER"
  chk "$1 disabledProofSystems = (false, false): neither proof system disabled" "$(call "$2" 'disabledProofSystems()((bool,bool))')" "(false, false)"
  chk "$1 getUserPriorityTxMaxGasLimit" "$(call "$2" 'getUserPriorityTxMaxGasLimit()(uint256)' | first)" "15000000"
  CHAIN_ADDR=$2 python3 - <<'PYFACETS' && echo "  OK   $1 facets, selectors and freezable flags = the cut's Adds" || fail "$1 facets, selectors or freezable flags"
import json, os, subprocess
E = os.environ
cast = lambda *a: subprocess.run(["cast", *a], capture_output=True, text=True, check=True).stdout.strip()
rpc = ["--rpc-url", E["RPC"]]
raw = cast("call", E["CHAIN_ADDR"], "facets()", *rpc)
got = sorted((f[0].lower(), sorted(s.lower() for s in f[1])) for f in json.loads(cast("abi-decode", "--json", "f()((address,bytes4[])[])", raw))[0])
adds = json.load(open(E["S"] + "/adds.json"))
ok = got == sorted((a.lower(), sorted(s.lower() for s in sels)) for a, _, sels in adds)
for a, frozen, sels in adds:
    for s in sels:
        if cast("call", E["CHAIN_ADDR"], "isFunctionFreezable(bytes4)(bool)", s, *rpc) != str(frozen).lower():
            print(f"     freezable flag differs: {a} {s}")
            ok = False
raise SystemExit(0 if ok else 1)
PYFACETS
}

echo "== The new MailboxFacet's address immutables equal chain $CHAIN_ID's live MailboxFacet's"
# The input's eip7702_checker was read from the live facet's code, which has no getter for it. Solc embeds
# immutables as PUSH32 words: compare the address-shaped ones (the ChainAssetHandler and the checker).
LIVE_MAILBOX=$(call "$DIAMOND" 'facetAddress(bytes4)(address)' "$(cast sig 'l2TransactionBaseCost(uint256,uint256,uint256)')")
python3 - "$LIVE_MAILBOX" "$(toml_get state_transition.mailbox_facet_addr)" <<'PYIMMUTABLES' && echo "  OK   both embed {ChainAssetHandler, EIP-7702 checker}" || fail "MailboxFacet address immutables differ from the live facet's"
import os, subprocess, sys

def address_words(address):
    code = bytes.fromhex(subprocess.run(["cast", "code", address, "--rpc-url", os.environ["RPC"]],
                                        capture_output=True, text=True, check=True).stdout.strip()[2:])
    words, i = set(), 0
    while i < len(code):
        op = code[i]
        if op == 0x7F and code[i + 1:i + 13] == bytes(12) and int.from_bytes(code[i + 1:i + 33], "big") >= 2**64:
            words.add("0x" + code[i + 13:i + 33].hex())
        i += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    return words

live, new = address_words(sys.argv[1]), address_words(sys.argv[2])
print(f"     live {sys.argv[1]}: {sorted(live)}; new: {sorted(new)}")
sys.exit(0 if live == new == {os.environ["CAH"].lower(), os.environ["EIP7702_CHECKER"].lower()} else 1)
PYIMMUTABLES

# A reference chain with a pending L2 upgrade (mainnet's 324 right after ZIP-18, until its first v0.33.0 batch
# executes) can't take v34 yet: its after-upgrade checks move to the test chain.
REF_UPGRADES=1
[ "$PENDING_L2_UPGRADE" = "0x0000000000000000000000000000000000000000000000000000000000000000" ] || REF_UPGRADES=0

# A fresh address with no code: well-known dev-key addresses can carry EIP-7702 code on Sepolia.
DEPOSITOR=0x5995a0003D4AbbF54CbD8C6B4DC3A83C1Ea5912B
# The 15M cap bounds the tx body: l2GasLimit minus the overhead, 10,000 with no calldata or factory deps.
CAP_GAS_LIMIT=15010000
GAS_PER_PUBDATA=800 # REQUIRED_L2_GAS_PRICE_PER_PUBDATA
GAS_PRICE=100000000000 # 100 gwei: the mint covers the base cost up to it (eth_calls run at gas price 0)
[ "$(cast code "$DEPOSITOR" --rpc-url "$RPC")" = "0x" ] || fail "depositor $DEPOSITOR has code on the fork"
cast rpc anvil_setBalance "$DEPOSITOR" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
# mint CHAIN — the base cost of a deposit just over the cap at GAS_PRICE. Every environment's chains use ETH.
mint() { call "$BRIDGEHUB" 'l2TransactionBaseCost(uint256,uint256,uint256,uint256)(uint256)' "$1" "$GAS_PRICE" $((CAP_GAS_LIMIT + 1)) "$GAS_PER_PUBDATA" | first; }
# deposit CHAIN MINT L2_GAS_LIMIT — requestL2TransactionDirect: no L2 value or calldata, refunds to the depositor.
deposit() {
  cast calldata 'requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))' \
    "($1,$2,$DEPOSITOR,0,0x,$3,$GAS_PER_PUBDATA,[],$DEPOSITOR)"
}
# cap_after LABEL CHAIN DIAMOND — the 15M cap on a v34 chain, then a deposit at the cap.
cap_after() {
  local m n
  m=$(mint "$2")
  case "$m" in '' | *[!0-9]*) fail "$1 l2TransactionBaseCost unreadable: ${m:-no answer}"; return ;; esac
  calls "$1 l2GasLimit 15,010,000 (body = 15M) is accepted" "$DEPOSITOR" "$BRIDGEHUB" "$(deposit "$2" "$m" "$CAP_GAS_LIMIT")" "$m"
  reverts "$1 l2GasLimit 15,010,001 reverts with TooMuchGas" "$DEPOSITOR" "$BRIDGEHUB" "$(deposit "$2" "$m" $((CAP_GAS_LIMIT + 1)))" 'TooMuchGas()' "$m"
  n=$(call "$3" 'getTotalPriorityTxs()(uint256)' | first)
  send "$DEPOSITOR" "$BRIDGEHUB" "$(deposit "$2" "$m" "$CAP_GAS_LIMIT")" "$1 a deposit with l2GasLimit 15,010,000 at 100 gwei" "$m" "$GAS_PRICE"
  emitted "$1 NewPriorityRequestId($n, …) emitted by the chain" "$3" 'NewPriorityRequestId(uint256,bytes32)' "$n" -
  chk "$1 getTotalPriorityTxs up by one" "$(call "$3" 'getTotalPriorityTxs()(uint256)' | first)" "$((n + 1))"
}

echo "== Chain $CHAIN_ID's cap on user L1->L2 transactions, before the upgrade (a depositor's eth_call)"
MINT=$(mint "$CHAIN_ID")
case "$MINT" in '' | *[!0-9]*) fail "chain $CHAIN_ID's l2TransactionBaseCost unreadable: ${MINT:-no answer}" ;; esac
calls "before v34: l2GasLimit 15,010,001 is accepted" "$DEPOSITOR" "$BRIDGEHUB" "$(deposit "$CHAIN_ID" "$MINT" $((CAP_GAS_LIMIT + 1)))" "$MINT"

if [ "$REF_UPGRADES" = "1" ]; then
  echo "== Chain $CHAIN_ID's upgrade, sent by the ChainAdmin's owner"
  send "$CHAIN_ADMIN_OWNER" "$CHAIN_ADMIN" "$UPGRADE_CALLDATA" "ChainAdmin multicall(upgradeChainFromVersion)"
  chain_state "chain $CHAIN_ID:" "$DIAMOND"
  chk "chain $CHAIN_ID: L2 upgrade tx hash = keccak(abi.encode(tx))" "$(call "$DIAMOND" 'getL2SystemContractsUpgradeTxHash()(bytes32)')" "$EXP_L2_TX_HASH"
  chk "chain $CHAIN_ID: priorityTxMaxGasLimit unchanged" "$(call "$DIAMOND" 'getPriorityTxMaxGasLimit()(uint256)' | first)" "$B_PRIORITY_LIMIT"
  echo "== Chain $CHAIN_ID's cap on user L1->L2 transactions on v34"
  cap_after "chain $CHAIN_ID v34:" "$CHAIN_ID" "$DIAMOND"
else
  echo "== Chain $CHAIN_ID has a pending L2 upgrade: its v34 upgrade must wait for it"
  reverts "upgrade reverts with PreviousUpgradeNotFinalized" "$CHAIN_ADMIN_OWNER" "$CHAIN_ADMIN" "$UPGRADE_CALLDATA" \
    'PreviousUpgradeNotFinalized(bytes32)'
  for c in "state after the upgrade (the test chain's covers it)" "L2 upgrade tx hash" "priorityTxMaxGasLimit unchanged"; do
    echo "  SKIP chain $CHAIN_ID: $c"; SKIPPED=$((SKIPPED + 1))
  done
fi

echo "== Chain $CHAIN_ID's first v34 batches, committed, proved and executed in forge's fork of this fork"
FIRST_BATCH_TESTS=8 # the test_ functions in V34EraStageFirstBatch.t.sol
# first_batches — the last v33 batch's stored info from its execute tx, then the fork test. Stops at the first failure.
first_batches() {
  local committed verified executed topic0 window from n=0 h prev want out_dir wt_dir lc_out lc_wt
  read -r committed verified executed <<< "$(counts)"
  case "$executed" in '' | *[!0-9]*) fail "first v34 batches: not run (chain $CHAIN_ID's batch counts unreadable)"; return ;; esac
  if [ "$committed" != "$executed" ] || [ "$verified" != "$executed" ] \
    || [ "$(call "$DIAMOND" 'getProtocolVersion()(uint256)' | first)" != "$NEW" ]; then
    fail "first v34 batches: not run (chain $CHAIN_ID not drained or not on v0.34.0)"; return
  fi
  case "$START_BLOCK" in '' | *[!0-9]*) fail "first v34 batches: not run (no start block)"; return ;; esac

  # Only the calldata of the tx that executed it has the full stored info. Before START_BLOCK, Anvil asks upstream.
  topic0=$(cast keccak 'BlockExecution(uint256,bytes32,bytes32)')
  for window in 5000 50000; do
    # window blocks up to START_BLOCK inclusive: public RPCs cap a log search at 50,000 blocks.
    from=$((START_BLOCK > window ? START_BLOCK - window + 1 : 0))
    cast logs --rpc-url "$RPC" --address "$DIAMOND" --from-block "$from" --to-block "$START_BLOCK" --json \
      "$topic0" "$(cast to-uint256 "$executed")" > "$S/execution_logs.json" 2> "$S/execution_logs.err" \
      || { fail "first v34 batches: cast logs failed: $(head -c 300 "$S/execution_logs.err")"; return; }
    n=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$S/execution_logs.json") \
      || { fail "first v34 batches: cast logs gave no JSON"; return; }
    [ "$n" = "0" ] || break
  done
  [ "$n" = "1" ] || { fail "first v34 batches: $n BlockExecution logs for batch $executed in the $window blocks before $START_BLOCK"; return; }
  h=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[0]["transactionHash"])' "$S/execution_logs.json")
  cast tx "$h" input --rpc-url "$RPC" > "$S/execute_input.hex" 2> "$S/execute_input.err" \
    || { fail "first v34 batches: cannot read tx $h: $(head -c 300 "$S/execute_input.err")"; return; }
  prev=$(python3 - "$S/execute_input.hex" "$executed" <<'PYPREV'
import json, os, subprocess, sys

def cast(*args):
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"     cast {args[0]} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()

SIG = "executeBatchesSharedBridge(address,uint256,uint256,bytes)"
# v33's StoredBatchInfo (no airbenderCommitment) and execute data, after the version byte 0x01.
STORED = "(uint64,bytes32,uint64,uint256,bytes32,bytes32,bytes32,uint256,bytes32)"
EXECUTE = f"f({STORED}[],(bytes32[],bytes32[],bytes32[])[],(uint256,uint256,bytes32[])[][],(uint8,bool,uint16,address,bytes32,bytes32)[][],bytes[][],bytes32[],address)"
tx_input, batch = open(sys.argv[1]).read().strip(), int(sys.argv[2])
if tx_input[:10] != cast("sig", SIG):
    raise SystemExit(f"     not {SIG}: {tx_input[:10]}")
# --json: the plain output appends annotations such as [1.077e5].
chain, _, _, data = json.loads(cast("calldata-decode", "--json", SIG, tx_input))
if chain.lower() != os.environ["DIAMOND"].lower() or data[:4] != "0x01":
    raise SystemExit(f"     not chain {os.environ['CHAIN_ID']}'s v33 execute data: chain {chain}, version byte {data[:4]}")
stored = [b for b in json.loads(cast("abi-decode", "--input", "--json", EXECUTE, "0x" + data[4:]))[0] if int(str(b[0]), 0) == batch]
if len(stored) != 1:
    raise SystemExit(f"     batch {batch} appears {len(stored)} times in the execute data")
print(cast("abi-encode", f"f({STORED})", "(" + ",".join(str(x) for x in stored[0]) + ")"))
PYPREV
  ) || { fail "first v34 batches: batch $executed's execute tx $h does not decode (see above)"; return; }
  want=$(call "$DIAMOND" 'storedBatchHash(uint256)(bytes32)' "$executed")
  [ -n "$want" ] && [ "$(cast keccak "$prev" | tr A-F a-f)" = "$(echo "$want" | tr A-F a-f)" ] \
    || { fail "first v34 batches: batch $executed's stored info from tx $h does not hash to storedBatchHash ${want:-(unreadable)}"; return; }
  echo "  OK   batch $executed's stored info, decoded from its execute tx $h, reproduces storedBatchHash"

  # Step 1 needs out/, zkout/ and cache-forge/ to hold the CI build and nothing else.
  FORK_TEST_OUT=${FORK_TEST_OUT:-$S/forge}
  out_dir=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$FORK_TEST_OUT") && wt_dir=$(cd "$WT" && pwd -P) \
    || { fail "first v34 batches: cannot resolve FORK_TEST_OUT=$FORK_TEST_OUT"; return; }
  # Compared in lower case: macOS file systems ignore case.
  lc_out=$(echo "$out_dir/" | tr '[:upper:]' '[:lower:]'); lc_wt=$(echo "$wt_dir" | tr '[:upper:]' '[:lower:]')
  case "$lc_out" in "$lc_wt/" | "$lc_wt"/out/* | "$lc_wt"/zkout/* | "$lc_wt"/cache-forge/*)
    fail "first v34 batches: FORK_TEST_OUT must be outside l1-contracts/{out,zkout,cache-forge}"; return ;;
  esac
  echo "     forge test, build in $out_dir"
  (cd "$WT" && V34_PREV_BATCH="$prev" forge test --fork-url "$RPC" --no-storage-caching \
    --match-path test/foundry/fork/V34EraStageFirstBatch.t.sol --out "$out_dir/out" --cache-path "$out_dir/cache" \
    --json > "$S/first_batch.json" 2> "$S/first_batch.err")
  # Every test must pass: a skipped or missing one fails too.
  python3 - "$S/first_batch.json" "$FIRST_BATCH_TESTS" <<'PYFORGE' && echo "  OK   first v34 batches: all $FIRST_BATCH_TESTS fork tests passed" \
    || { fail "first v34 batches (forge stderr: $S/first_batch.err)"; tail -30 "$S/first_batch.err" | sed 's/^/     /'; }
import json, sys
try:
    suites = json.load(open(sys.argv[1]))
except ValueError as e:
    raise SystemExit(f"     forge wrote no JSON results: {e}")
results = [(f"{suite.split(':')[-1]}.{name}", t["status"], t.get("reason")) for suite, r in suites.items() for name, t in r["test_results"].items()]
for name, status, reason in results:
    if status != "Success":
        print(f"     {status} {name}: {reason}")
passed = sum(status == "Success" for _, status, _ in results)
print(f"     {passed} of {len(results)} passed, {sys.argv[2]} expected")
sys.exit(0 if passed == len(results) == int(sys.argv[2]) else 1)
PYFORGE
}
case "$FIRST_BATCH_TEST" in
  # A reference chain that couldn't upgrade (a pending L2 upgrade) has no v34 batches to test.
  1) if [ "$REF_UPGRADES" = "1" ]; then first_batches; else
       echo "  SKIP first v34 batches (chain $CHAIN_ID not upgraded: pending L2 upgrade)"; SKIPPED=$((SKIPPED + 1)); fi ;;
  0) echo "  SKIP first v34 batches (set FIRST_BATCH_TEST=1)"; SKIPPED=$((SKIPPED + 1)) ;;
  *) fail "FIRST_BATCH_TEST must be 0 or 1, got '$FIRST_BATCH_TEST'" ;;
esac

echo "== Test chain created with the new params, as the bridgehub admin"
read -r TC_TARGET TC_DATA < "$S/test_create_chain.txt"
send "$ECO_ADMIN" "$TC_TARGET" "$TC_DATA" "createNewChain($TEST_CHAIN_ID)"
NEW_CHAIN=$(call "$BRIDGEHUB" 'getZKChain(uint256)(address)' "$TEST_CHAIN_ID")
if [ "$NEW_CHAIN" != "0x0000000000000000000000000000000000000000" ]; then
  chain_state "test chain:" "$NEW_CHAIN"
else
  fail "test chain not registered"
fi

BOOJUM=0 AIRBENDER=1 # ProofSystem ordinals; the disabledProofSystems mask bit is 1 << ordinal
SET_PS='setProofSystemStatus(uint8,bool)'
NOTIFY_PS='notifyProofSystemStatus(uint256,(bool,bool))'
MULTICALL='multicall((address,uint256,bytes)[],bool)'
# proof_switches LABEL CHAIN DIAMOND CHAIN_ADMIN CHAIN_ADMIN_OWNER — through the ChainAdmin: disable Airbender
# (both events), disabling Boojum too reverts, re-enable; sent directly, both calls revert. Run last: it changes
# disabledProofSystems, which chain_state expects at (false, false), and restores it.
proof_switches() {
  local notify set
  echo "== $1's proof-system switches, sent by the ChainAdmin's owner"
  chk "verifier supportedProofSystems = Boojum | Airbender" "$(call "$VERIFIER" 'supportedProofSystems()(uint8)')" 3
  reverts "setProofSystemStatus from the ChainAdmin's owner directly reverts" "$5" "$3" \
    "$(cast calldata "$SET_PS" "$AIRBENDER" false)" 'Unauthorized(address)'
  reverts "notifyProofSystemStatus from the ChainAdmin's owner directly reverts" "$5" "$SN" \
    "$(cast calldata "$NOTIFY_PS" "$2" '(false,true)')" 'Unauthorized(address)'
  notify=$(cast calldata "$NOTIFY_PS" "$2" '(false,true)')
  set=$(cast calldata "$SET_PS" "$AIRBENDER" false)
  send "$5" "$4" "$(cast calldata "$MULTICALL" "[($SN,0,$notify),($3,0,$set)]" true)" \
    "ChainAdmin multicall(notify (false, true), disable Airbender)"
  emitted "ProofSystemStatusNotified($2, (false, true)) emitted by the ServerNotifier" "$SN" \
    'ProofSystemStatusNotified(uint256,(bool,bool))' "$2" "$(cast abi-encode 'f(bool,bool)' false true)"
  emitted "NewDisabledProofSystems(0, 2) emitted by $1" "$3" 'NewDisabledProofSystems(uint8,uint8)' "0 2" 0x
  chk "$1: disabledProofSystems = (false, true)" "$(call "$3" 'disabledProofSystems()((bool,bool))')" "(false, true)"
  reverts "disabling Boojum too reverts with InvalidDisabledProofSystemsMask" "$5" "$4" \
    "$(cast calldata "$MULTICALL" "[($3,0,$(cast calldata "$SET_PS" "$BOOJUM" false))]" true)" 'InvalidDisabledProofSystemsMask(uint8)'
  notify=$(cast calldata "$NOTIFY_PS" "$2" '(false,false)')
  set=$(cast calldata "$SET_PS" "$AIRBENDER" true)
  send "$5" "$4" "$(cast calldata "$MULTICALL" "[($SN,0,$notify),($3,0,$set)]" true)" \
    "ChainAdmin multicall(notify (false, false), re-enable Airbender)"
  emitted "ProofSystemStatusNotified($2, (false, false)) emitted by the ServerNotifier" "$SN" \
    'ProofSystemStatusNotified(uint256,(bool,bool))' "$2" "$(cast abi-encode 'f(bool,bool)' false false)"
  emitted "NewDisabledProofSystems(2, 0) emitted by $1" "$3" 'NewDisabledProofSystems(uint8,uint8)' "2 0" 0x
  chk "$1: disabledProofSystems = (false, false) again" "$(call "$3" 'disabledProofSystems()((bool,bool))')" "(false, false)"
}

if [ "$REF_UPGRADES" = "1" ]; then
  proof_switches "chain $CHAIN_ID" "$CHAIN_ID" "$DIAMOND" "$CHAIN_ADMIN" "$CHAIN_ADMIN_OWNER"
elif [ "$NEW_CHAIN" != "0x0000000000000000000000000000000000000000" ]; then
  echo "== Moved to test chain $TEST_CHAIN_ID: the cap on v34 and the proof-system switches"
  MOVING=1
  cap_after "test chain:" "$TEST_CHAIN_ID" "$NEW_CHAIN"
  # Its admin is the bridgehub admin (an Ownable ChainAdmin), which the ServerNotifier also accepts.
  proof_switches "test chain $TEST_CHAIN_ID" "$TEST_CHAIN_ID" "$NEW_CHAIN" "$ECO_ADMIN" "$ECO_ADMIN_OWNER"
  MOVING=0
else
  fail "the moved checks: no test chain"
fi

echo
checks() { [ "$1" = "1" ] && echo "1 check" || echo "$1 checks"; }
NOTE=
[ "$SKIPPED" = "0" ] || NOTE="$(checks "$SKIPPED") skipped"
[ "$MOVED" = "0" ] || NOTE="${NOTE:+$NOTE, }$(checks "$MOVED") moved to the test chain"
if [ "$FAILED" = "0" ]; then
  echo "REHEARSAL PASSED${NOTE:+ ($NOTE)}"
else
  echo "REHEARSAL FAILED ($FAILED)${NOTE:+ ($NOTE)}"
  exit 1
fi
