#!/bin/bash
# Shared helpers for the v31 ecosystem-upgrade fork flows.
#
# Sourced by:
#   - `regen-and-verify.sh`        — GENERATE: fork, prepare, replay, PUVT.
#   - `replay-bundle-and-verify.sh` — CONSUME: replay a already-generated deploy
#                                     bundle onto a fork (or real L1) and PUVT it.
#
# Both need the same primitives (read a scalar out of the env TOMLs, find the
# `protocol_ops` binary, start a pinned anvil fork, fund every bundle target),
# so they live here instead of being copy-pasted between the two.
#
# This file only defines functions — sourcing it has no side effects.

# Read a top-level scalar string (`key = "value"`) out of a TOML file.
# $1 = file, $2 = key. Prints the empty string when the key is absent.
read_toml_str() {
  python3 -c "
import re, sys
m = re.search(r'^${2}\s*=\s*[\"\']([^\"\']+)', open('${1}').read(), re.MULTILINE)
print(m.group(1) if m else '', end='')
"
}

# Read a top-level scalar integer (`key = 123`) out of a TOML file.
# Matches the digits AFTER the `=` so keys that themselves contain digits
# (`l1_chain_id`) don't self-match. Prints the empty string when absent.
read_toml_int() {
  sed -nE "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$1" | head -1
}

# Print the SHA-256 digest of one file. Python keeps this portable across Linux
# CI and developer machines where `sha256sum` may not be installed.
# $1 = file.
file_sha256() {
  python3 - "$1" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as source:
    print(hashlib.sha256(source.read()).hexdigest())
PY
}

# Restore the canonical v31 DefaultAccount compiler-metadata word after a clean
# foundry-zksync build. The v0.31 release artifact and a clean GitHub runner have
# identical executable bytes but can differ in the final 32-byte metadata word.
# We only normalize the one reviewed executable prefix, then require the result
# to match both the selected env config and AllContractsHashes.json.
# $1 = generated DefaultAccount artifact, $2 = v31 env TOML,
# $3 = AllContractsHashes.json.
restore_v31_default_account_artifact() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import os
import re
import sys

artifact_path, env_path, hashes_path = sys.argv[1:]

# Canonical artifact from the #2268 merge build (workflow run 33096868698).
CANONICAL_HASH = "0x010005f9d84c1863bf21a9393f2fd1631af92aab68f12c35dba580c8d7a06146"
CANONICAL_EXECUTABLE_SHA256 = "28c736311a2f872a0b8ff289b0ae35266f1ccd402885435fd9ffd2a154a39a96"
CANONICAL_METADATA_WORD = bytes.fromhex(
    "3ad06056e66b778b11945dd3cf11269b479679b45850c25af96c8ca9f309acb0"
)
METADATA_WORD_BYTES = 32

def fail(message):
    raise SystemExit(f"canonical DefaultAccount restore failed: {message}")

def zk_bytecode_hash(bytecode):
    if len(bytecode) % 32 != 0:
        fail(f"bytecode length {len(bytecode)} is not word-aligned")
    words = len(bytecode) // 32
    if words % 2 != 1 or words > 0xFFFF:
        fail(f"invalid EraVM bytecode word length {words}")
    digest = bytearray(hashlib.sha256(bytecode).digest())
    digest[0:2] = b"\x01\x00"
    digest[2:4] = words.to_bytes(2, "big")
    return "0x" + digest.hex()

with open(env_path) as source:
    match = re.search(r'^default_aa_hash\s*=\s*"(0x[0-9a-fA-F]{64})"', source.read(), re.MULTILINE)
if not match:
    fail(f"{env_path} has no top-level default_aa_hash")
env_hash = match.group(1).lower()

with open(hashes_path) as source:
    hashes = json.load(source)
reviewed = [
    entry.get("zkBytecodeHash", "").lower()
    for entry in hashes
    if entry.get("contractName") == "system-contracts/DefaultAccount"
]
if reviewed != [env_hash]:
    fail(f"env hash {env_hash} does not uniquely match AllContractsHashes.json: {reviewed}")

with open(artifact_path) as source:
    artifact = json.load(source)
raw = artifact.get("bytecode", {}).get("object")
if not isinstance(raw, str) or not re.fullmatch(r"(?:0x)?[0-9a-fA-F]+", raw):
    fail(f"{artifact_path} has no bytecode.object")
hex_prefix = "0x" if raw.startswith("0x") else ""
bytecode = bytes.fromhex(raw.removeprefix("0x"))
built_hash = zk_bytecode_hash(bytecode)
if built_hash == env_hash:
    print(f"DefaultAccount artifact already canonical: {built_hash}")
    raise SystemExit(0)
if env_hash != CANONICAL_HASH:
    fail(f"no canonical artifact registered for env hash {env_hash} (build produced {built_hash})")
if len(bytecode) <= METADATA_WORD_BYTES:
    fail("bytecode is too short to contain the metadata word")
executable = bytecode[:-METADATA_WORD_BYTES]
executable_sha256 = hashlib.sha256(executable).hexdigest()
if executable_sha256 != CANONICAL_EXECUTABLE_SHA256:
    fail(
        f"executable prefix changed: expected {CANONICAL_EXECUTABLE_SHA256}, "
        f"got {executable_sha256}"
    )

canonical = executable + CANONICAL_METADATA_WORD
canonical_hash = zk_bytecode_hash(canonical)
if canonical_hash != env_hash:
    fail(f"restored hash {canonical_hash} does not match reviewed hash {env_hash}")
artifact["bytecode"]["object"] = hex_prefix + canonical.hex()
temporary_path = artifact_path + ".tmp"
with open(temporary_path, "w") as destination:
    json.dump(artifact, destination, separators=(",", ":"))
    destination.write("\n")
os.replace(temporary_path, artifact_path)
print(f"Restored canonical DefaultAccount artifact: {built_hash} -> {canonical_hash}")
PY
}

# Fail unless every executable/supporting file in a deploy bundle matches the
# SHA-256 recorded by `pack-deploy-bundle.sh`, and the metadata's bundle list is
# exactly the list the manifest will execute. This is called before fork replay
# and before real-L1 broadcast.
# $1 = deploy-bundle directory.
verify_bundle_integrity() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import re
import sys

bundle = os.path.realpath(sys.argv[1])
metadata_path = os.path.join(bundle, "bundle-metadata.json")
manifest_path = os.path.join(bundle, "prepare", "manifest.json")

def fail(message):
    raise SystemExit(f"deploy bundle integrity check failed: {message}")

def load_json(path, label):
    try:
        with open(path) as source:
            return json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")

def checked_path(relative_path):
    if not isinstance(relative_path, str) or not relative_path:
        fail("metadata contains an empty/non-string file path")
    path = os.path.realpath(os.path.join(bundle, relative_path))
    if os.path.commonpath([bundle, path]) != bundle:
        fail(f"file escapes bundle directory: {relative_path}")
    if not os.path.isfile(path):
        fail(f"missing file: {relative_path}")
    return path

def verify_digest(relative_path, expected):
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        fail(f"invalid SHA-256 for {relative_path}")
    with open(checked_path(relative_path), "rb") as source:
        actual = hashlib.sha256(source.read()).hexdigest()
    if actual != expected:
        fail(f"SHA-256 mismatch for {relative_path}: expected {expected}, got {actual}")

metadata = load_json(metadata_path, "bundle-metadata.json")
manifest = load_json(manifest_path, "prepare/manifest.json")
if metadata.get("schema") != "zksync-ecosystem-upgrade-deploy-bundle/1":
    fail(f"unsupported schema: {metadata.get('schema')!r}")

metadata_bundles = metadata.get("bundles")
manifest_bundles = manifest.get("bundles")
if not isinstance(metadata_bundles, list) or not metadata_bundles:
    fail("metadata.bundles is empty or not an array")
if not isinstance(manifest_bundles, list) or not manifest_bundles:
    fail("manifest.bundles is empty or not an array")

def identity(entry):
    try:
        return (int(entry["index"]), entry["file"], entry["target"].lower())
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        fail(f"invalid bundle identity: {error}")

metadata_identities = [identity(entry) for entry in metadata_bundles]
manifest_identities = [identity(entry) for entry in manifest_bundles]
if len(set(metadata_identities)) != len(metadata_identities):
    fail("metadata contains duplicate bundle identities")
if sorted(metadata_identities) != sorted(manifest_identities):
    fail("metadata bundle list does not match prepare/manifest.json")

for entry in metadata_bundles:
    relative_path = os.path.join("prepare", entry["file"])
    verify_digest(relative_path, entry.get("sha256"))
    safe = load_json(checked_path(relative_path), relative_path)
    transactions = safe.get("transactions")
    if not isinstance(transactions, list):
        fail(f"{relative_path} has no transactions array")
    if len(transactions) != entry.get("transaction_count"):
        fail(f"transaction count mismatch for {relative_path}")

supporting_files = metadata.get("files")
if not isinstance(supporting_files, dict) or not supporting_files:
    fail("metadata.files is empty or not an object")
for required in ("prepare/manifest.json", "ecosystem.toml"):
    if required not in supporting_files:
        fail(f"metadata.files does not include {required}")
for relative_path, expected in supporting_files.items():
    verify_digest(relative_path, expected)

print(
    f"Deploy bundle integrity: OK "
    f"({len(metadata_bundles)} bundle(s), {len(supporting_files)} supporting file(s))"
)
PY
}

# Base anvil port for an env's GENERATE fork. Each env gets a distinct port so
# stage/testnet/mainnet rehearsals can run in parallel without colliding (and a
# KEEP_ANVIL fork of one env is never reused by another).
#
# The CONSUME flow (`replay-bundle-and-verify.sh`) uses base+1, so a bundle
# replay can run next to a generate rehearsal of the same env.
env_anvil_port() {
  case "$1" in
    stage) echo 29545 ;;
    testnet) echo 29547 ;;
    mainnet) echo 29549 ;;
    *)
      echo "Unknown env '$1' (expected: stage | testnet | mainnet)" >&2
      echo "Add a port for it here if it needs its own fork." >&2
      return 1
      ;;
  esac
}

# Locate the protocol_ops binary. Prefer the local debug build (devs iterate on
# this), then the release build, then anything on PATH (the Docker image puts it
# on PATH via /contracts/protocol-ops/).
# $1 = repo's protocol-ops directory. Prints the resolved path.
locate_protocol_ops() {
  local po_dir="$1"
  if [[ -x "$po_dir/target/debug/protocol_ops" ]]; then
    echo "$po_dir/target/debug/protocol_ops"
  elif [[ -x "$po_dir/target/release/protocol_ops" ]]; then
    echo "$po_dir/target/release/protocol_ops"
  elif [[ -x "$po_dir/protocol_ops" ]]; then
    echo "$po_dir/protocol_ops"
  elif command -v protocol_ops >/dev/null 2>&1; then
    command -v protocol_ops
  else
    echo "protocol_ops binary not found — build it with 'cd protocol-ops && cargo build --release'" >&2
    return 1
  fi
}

# Start an anvil fork and wait for it to serve.
# $1 = port, $2 = fork url, $3 = fork block (may be empty = tip), $4 = log path.
# Exports ANVIL_PID for the caller's cleanup trap.
start_anvil_fork() {
  local port="$1" fork_url="$2" fork_block="$3" log="$4"
  local anvil_args=(
    --port "$port"
    --auto-impersonate
    --disable-block-gas-limit
    --gas-price 1000000000
    --fork-url "$fork_url"
  )
  # Optional block pin. Needed when the live chain is mid- or post-upgrade:
  # forking the tip would inherit an already-applied stage (e.g. a started
  # GovernanceUpgradeTimer, or ownership already handed off from the deployer),
  # making the replay revert. Pin to a pre-upgrade block for a clean state.
  if [[ -n "$fork_block" ]]; then
    echo "    pinning fork to block $fork_block"
    anvil_args+=(--fork-block-number "$fork_block")
  fi
  anvil "${anvil_args[@]}" >"$log" 2>&1 &
  ANVIL_PID=$!
  local rpc="http://localhost:$port"
  local _
  for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  cast chain-id --rpc-url "$rpc" >/dev/null || { echo "anvil failed to start (see $log)" >&2; return 1; }
}

# Give every bundle signer the ETH (gas) and ZK (base-token burn) it needs, and
# pre-register the ZK asset id so gateway priority deposits pass.
#
# $1 = rpc, $2 = bridgehub, $3 = zk asset id, $4 = has_gateway (0|1),
# $5 = manifest.json, $6 = ecosystem.toml, $7 = deployer address.
#
# On the deployer-EOA-with-PUH-as-owner split the manifest targets are the
# deployer EOA, the security council EOA, AND PUH itself (PUH lands in the list
# because it owns a CTM/ProxyAdmin and the wrap script broadcasts the
# corresponding accept-ownership / transferOwnership txs from PUH).
fund_bundle_targets() {
  local rpc="$1" bridgehub="$2" zk_asset_id="$3" has_gateway="$4"
  local manifest="$5" ecosystem_toml="$6" deployer="$7"
  # 1e30 wei
  local fund_amount="1000000000000000000000000000000"

  local ar ntv zk_token
  ar=$(cast call "$bridgehub" "assetRouter()(address)" --rpc-url "$rpc")
  ntv=$(cast call "$ar" "nativeTokenVault()(address)" --rpc-url "$rpc")
  zk_token=$(cast call "$ntv" "tokenAddress(bytes32)(address)" "$zk_asset_id" --rpc-url "$rpc")
  echo "AR=$ar"
  echo "NTV=$ntv"
  echo "ZK_TOKEN=$zk_token"
  cast rpc anvil_setBalance "$ntv" 0x21e19e0c9bab2400000 --rpc-url "$rpc" >/dev/null

  local targets target
  targets=$(jq -r '.bundles[].target' "$manifest" | sort -u)
  echo "Bundle targets:"
  echo "$targets" | sed 's/^/  /'
  for target in $targets; do
    cast rpc anvil_setBalance "$target" 0x21e19e0c9bab2400000 --rpc-url "$rpc" >/dev/null
    if [[ "$has_gateway" == "1" ]]; then
      # Gateway-enabled env: ZK is the NTV-mintable new-GW base token and bundle
      # 5's GW priority tx burns it — funding must succeed.
      echo "  bridgeMint($target, $fund_amount)"
      cast send --from "$ntv" --unlocked "$zk_token" \
        "bridgeMint(address,uint256)" "$target" "$fund_amount" \
        --rpc-url "$rpc" >/dev/null
    else
      # Gateway-less env: the ZK token is L1-native (a plain ERC20, not
      # NTV-mintable, so bridgeMint reverts Unauthorized(NTV)) and unnecessary —
      # no GW priority tx burns ZK. Tolerate the revert; the ETH gas funding
      # above is all the fork replay needs.
      echo "  bridgeMint($target, $fund_amount) [best-effort]"
      cast send --from "$ntv" --unlocked "$zk_token" \
        "bridgeMint(address,uint256)" "$target" "$fund_amount" \
        --rpc-url "$rpc" >/dev/null 2>&1 || true
    fi
  done

  # Register the ZK token assetId in L1AssetTracker so bundle 5's GW priority
  # deposits (which burn ZK as the new-GW base token) pass the
  # `_requireRegistered` check on `handleChainBalanceIncreaseOnL1`. In production
  # this registration lands as stage-2 call 6 (`registerLegacyToken`), but the
  # bundles are replayed BEFORE governance, so we prime it here directly.
  # `registerLegacyToken` is public — anyone can call it.
  local asset_tracker
  asset_tracker=$(awk -F'"' '/^asset_tracker_proxy_addr[ \t]*=/{print $2; exit}' "$ecosystem_toml")
  if [ -n "$asset_tracker" ]; then
    echo "  registerLegacyToken($zk_asset_id) on $asset_tracker"
    cast send "$asset_tracker" "registerLegacyToken(bytes32)" "$zk_asset_id" \
      --from "$deployer" --unlocked --rpc-url "$rpc" >/dev/null || true
  else
    echo "  WARNING: asset_tracker_proxy_addr not found in $ecosystem_toml — skipping registerLegacyToken"
  fi
}

# Does this env bring up a new Gateway? Gateway-enabled envs (stage, mainnet)
# have a `[new_gateway]` table in permanent-values; their ZK token is the new-GW
# base token (NTV-mintable) and bundle 5's GW priority tx burns it, so ZK
# funding MUST succeed. Gateway-less envs (testnet) omit the table; their ZK
# token is L1-native (a plain ERC20, not NTV-mintable → bridgeMint reverts) and
# no GW priority tx burns ZK, so the funding is both impossible and unnecessary.
# $1 = permanent-values path. Prints 1 or 0.
env_has_gateway() {
  if grep -qE '^\[new_gateway\]' "$1"; then echo 1; else echo 0; fi
}
