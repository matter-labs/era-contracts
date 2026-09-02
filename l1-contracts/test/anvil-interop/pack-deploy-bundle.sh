#!/bin/bash
# Pack a v31 upgrade generation run into a self-contained DEPLOY BUNDLE.
#
#   ./pack-deploy-bundle.sh <env>
#
# Optional env vars, all recorded in `bundle-metadata.json` when set (the
# generate flow exports them; a hand-run pack just leaves them null):
#   DEPLOYER_ADDR             — the EOA whose bundles are the deployer's
#   FORKED_AT_BLOCK           — L1 height the bundles were computed against
#   ZK_GOVERNANCE_COMMIT      — zk-governance commit PUVT should use
#   ZKSYNC_FOUNDRY_VERSION    — foundry-zksync version used for the build
#   BUNDLE_DIR                — where to write (default: output/<env>/deploy-bundle)
#
# A generation run (`regen-and-verify.sh`, locally or in CI) computes the new
# ecosystem contracts ON A FORK and writes, per env, into
# `upgrade-envs/v0.31.0-interopB/output/<env>/`:
#
#   prepare/manifest.json + prepare/*.safe.json   the deployer calls to make
#   ecosystem.toml                                addresses + governance stages
#   extra-verification-logs.txt                   forge verify-contract commands
#
# WHY A BUNDLE. The `*.safe.json` transactions carry the CREATE2 **init code**
# of every new contract, i.e. the exact bytecode the generating machine compiled.
# Solidity output is not byte-stable across build environments (the default
# foundry profile embeds path-dependent CBOR metadata), so re-running the
# generation elsewhere legitimately produces different bytecode — and therefore
# different CREATE2 addresses and different governance calldata. The deploy
# bundle is what makes the run transferable: whoever broadcasts it deploys the
# generating machine's bytecode byte-for-byte, at the addresses the reviewed
# `ecosystem.toml` names, without compiling anything.
#
# `bundle-metadata.json` pins the provenance needed to check and replay that:
# the contracts commit (whose committed `AllContractsHashes.json` PUVT compares
# the deployed bytecode against), the forked block, the deployer, and the
# toolchain versions.
#
# Consumed by:
#   - `replay-bundle-and-verify.sh` — replay + PUVT it (locally or in CI).
#   - `deploy-ecosystem-upgrade.yaml` — broadcast the deployer bundles for real.

set -euo pipefail

# shellcheck source=./upgrade-bundle-lib.sh
source "$(dirname "$0")/upgrade-bundle-lib.sh"

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "usage: $0 <env>   (stage | testnet | mainnet)" >&2
  exit 1
fi

L1_CONTRACTS_DIR="$(cd "$(dirname "$0")"/../.. && pwd)"
REPO_ROOT="$(cd "$L1_CONTRACTS_DIR"/.. && pwd)"
OUT="$L1_CONTRACTS_DIR/upgrade-envs/v0.31.0-interopB/output/$ENV"
BUNDLE="${BUNDLE_DIR:-$OUT/deploy-bundle}"
PERMANENT_VALUES="$L1_CONTRACTS_DIR/upgrade-envs/permanent-values/$ENV.toml"

for f in "$OUT/ecosystem.toml" "$OUT/prepare/manifest.json"; do
  [[ -f "$f" ]] || { echo "missing generation output: $f (run regen-and-verify.sh first)" >&2; exit 1; }
done

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/prepare"

cp "$OUT/ecosystem.toml" "$BUNDLE/ecosystem.toml"
cp "$OUT/prepare/manifest.json" "$BUNDLE/prepare/manifest.json"
cp "$OUT"/prepare/*.safe.json "$BUNDLE/prepare/"
# The verify-contract command logs carry the exact `--constructor-args` taken
# from the deployed init code, so Etherscan verification needs no guessing.
# `gw-verification-logs.txt` only exists (non-empty) on gateway-enabled envs.
for log in extra-verification-logs.txt gw-verification-logs.txt; do
  if [[ -s "$OUT/$log" ]]; then cp "$OUT/$log" "$BUNDLE/$log"; fi
done

# ── provenance ───────────────────────────────────────────────────────────────
# Every field here answers a question a replayer/reviewer has to be able to
# answer: which source produced this bytecode (contracts_commit +
# all_contracts_hashes_sha256), against which chain state (l1.*), signed by whom
# (deployer_address), with which tools (toolchain).
CONTRACTS_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
CONTRACTS_DIRTY=false
# `--ignore-submodules=all`: a checkout's submodule pointers routinely read as
# modified (worktrees, different lib/ checkouts) and say nothing about the
# contract sources that were compiled.
if ! git -C "$REPO_ROOT" diff --quiet HEAD --ignore-submodules=all 2>/dev/null; then CONTRACTS_DIRTY=true; fi
HASHES_SHA="$(file_sha256 "$REPO_ROOT/AllContractsHashes.json")"
L1_CHAIN_ID="$(read_toml_int "$PERMANENT_VALUES" l1_chain_id)"
FORGE_VERSION="$(forge --version 2>/dev/null | head -1 || echo unknown)"
RUSTC_VERSION="$(rustc --version 2>/dev/null || echo unknown)"
CREATE2_FACTORY="$(read_toml_str "$PERMANENT_VALUES" create2_factory_addr)"

BUNDLE="$BUNDLE" \
ENV="$ENV" \
CONTRACTS_COMMIT="$CONTRACTS_COMMIT" \
CONTRACTS_DIRTY="$CONTRACTS_DIRTY" \
HASHES_SHA="$HASHES_SHA" \
L1_CHAIN_ID="$L1_CHAIN_ID" \
FORGE_VERSION="$FORGE_VERSION" \
RUSTC_VERSION="$RUSTC_VERSION" \
CREATE2_FACTORY="$CREATE2_FACTORY" \
ECOSYSTEM_TOML="$BUNDLE/ecosystem.toml" \
python3 - <<'PY'
import hashlib, json, os, re

bundle = os.environ["BUNDLE"]
manifest = json.load(open(f"{bundle}/prepare/manifest.json"))
deployer = (os.environ.get("DEPLOYER_ADDR") or "").lower()

create2_factory = (os.environ.get("CREATE2_FACTORY") or "").lower()

def sha256(path):
    with open(path, "rb") as source:
        return hashlib.sha256(source.read()).hexdigest()

bundles = []
calls_md = []
for b in sorted(manifest["bundles"], key=lambda b: b["index"]):
    path = f"{bundle}/prepare/{b['file']}"
    safe = json.load(open(path))
    txs = safe.get("transactions", [])
    # A flat, reviewable listing of what will actually be sent. `data` itself can
    # be hundreds of KB of init code, so show its size + selector and point at
    # the JSON for the bytes.
    role = "DEPLOYER" if deployer and b["target"].lower() == deployer else "other signer"
    calls_md.append(
        f"\n### Bundle {b['index']} — signer `{b['target']}` ({role})\n\n"
        f"`{b['file']}` · {len(txs)} transaction(s)\n\n"
        "| # | to | value | kind | selector / CREATE2 salt | data bytes |\n|---|---|---|---|---|---|"
    )
    for n, tx in enumerate(txs, 1):
        data = tx.get("data") or "0x"
        to = (tx.get("to") or "").lower()
        if to == create2_factory:
            # Arachnid factory calldata is salt(32 bytes) ++ init code.
            kind, tag = "CREATE2 deploy", "0x" + data[2:66]
        else:
            kind, tag = "call", data[:10]
        calls_md.append(
            f"| {n} | `{tx.get('to')}` | {tx.get('value', '0')} | {kind} | `{tag}` |"
            f" {max(len(data) - 2, 0) // 2} |"
        )
    bundles.append({
        "index": b["index"],
        "file": b["file"],
        "target": b["target"],
        "steps": b.get("steps", []),
        "transaction_count": len(txs),
        "is_deployer_bundle": b["target"].lower() == deployer if deployer else None,
        "sha256": sha256(path),
    })

# Which deployments have the deployer baked INTO their init code — i.e. whose
# CREATE2 address moves if a different EOA broadcasts. The prepare passes the
# deployer as the initial owner of a couple of proxies (`initialize(deployer)`)
# and to the verifier's constructor, so those addresses are a function of the
# deployer, not just of the salt and the init code. Read off the logged
# `--constructor-args`, which is exactly what went into the init code.
#
# This is why the deployer is NOT a free parameter: whoever broadcasts must be the
# EOA the bundle was generated for, or these land elsewhere and the governance
# calldata in `ecosystem.toml` points at contracts that were never deployed.
deployer_dependent = []
verify_log = f"{bundle}/extra-verification-logs.txt"
if deployer and os.path.exists(verify_log):
    pat = re.compile(
        r"forge verify-contract\s+(0x[0-9a-fA-F]{40})\s+(\S+)\s+--constructor-args\s+(0x[0-9a-fA-F]+)"
    )
    seen = set()
    for addr, name, args in pat.findall(open(verify_log).read()):
        if deployer[2:] in args.lower() and addr.lower() not in seen:
            seen.add(addr.lower())
            deployer_dependent.append({"address": addr, "contract": name})

# Protocol version transition, as recorded per CTM flavor in ecosystem.toml.
toml = open(os.environ["ECOSYSTEM_TOML"]).read()
def ints(key):
    return sorted({int(v) for v in re.findall(rf"^{key}\s*=\s*(\d+)", toml, re.M)})
def hexes(key):
    return [hex(v) for v in ints(key)]

# Digests for every non-bundle file consumed by replay, deployment, PUVT or
# Etherscan verification. The Safe JSON digests live beside their bundle entries.
supporting_files = {}
for relative_path in (
    "prepare/manifest.json",
    "ecosystem.toml",
    "extra-verification-logs.txt",
    "gw-verification-logs.txt",
):
    path = os.path.join(bundle, relative_path)
    if os.path.isfile(path):
        supporting_files[relative_path] = sha256(path)

meta = {
    "schema": "zksync-ecosystem-upgrade-deploy-bundle/1",
    "upgrade": "v0.31.0-interopB",
    "env": os.environ["ENV"],
    "protocol_version": {
        "old": hexes("old_protocol_version"),
        "new": hexes("new_protocol_version"),
    },
    # The bytecode identity of this bundle. PUVT resolves the deployed code
    # against the `AllContractsHashes.json` of THIS commit, so a replayer must
    # check out this commit (or pass `--contracts-commit`).
    "contracts_commit": os.environ["CONTRACTS_COMMIT"],
    "contracts_worktree_dirty": os.environ["CONTRACTS_DIRTY"] == "true",
    "all_contracts_hashes_sha256": os.environ["HASHES_SHA"],
    "l1": {
        "chain_id": int(os.environ["L1_CHAIN_ID"]) if os.environ.get("L1_CHAIN_ID") else None,
        # The fork height the bundles were computed against. Replay against this
        # same height; a later state can diverge (ownership handed off, timer
        # started) and make the replay revert.
        "forked_at_block": int(os.environ["FORKED_AT_BLOCK"]) if os.environ.get("FORKED_AT_BLOCK") else None,
    },
    "deployer_address": os.environ.get("DEPLOYER_ADDR") or None,
    # Deployments whose CREATE2 address depends on `deployer_address` (it is in
    # their init code). The broadcasting EOA must be that same address.
    "deployer_dependent_deployments": deployer_dependent,
    "zk_governance_commit": os.environ.get("ZK_GOVERNANCE_COMMIT") or None,
    "toolchain": {
        "forge": os.environ["FORGE_VERSION"],
        "rustc": os.environ["RUSTC_VERSION"],
        "foundry_zksync": os.environ.get("ZKSYNC_FOUNDRY_VERSION") or None,
    },
    # Set when packed by CI; a human-packed bundle leaves it null.
    "generated_by": ({
        "workflow_run": f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "runner_os": os.environ.get("RUNNER_OS"),
    } if os.environ.get("GITHUB_RUN_ID") else None),
    "files": supporting_files,
    "bundles": bundles,
}
json.dump(meta, open(f"{bundle}/bundle-metadata.json", "w"), indent=2, sort_keys=True)
open(f"{bundle}/bundle-metadata.json", "a").write("\n")

# ── README: the exact commands to consume this bundle ──────────────────────
deployer_files = [b["file"] for b in bundles if b["is_deployer_bundle"]]
other = [(b["target"], b["file"]) for b in bundles if not b["is_deployer_bundle"]]
env = meta["env"]
readme = f"""# v31 deploy bundle — `{env}`

Generated from era-contracts `{meta['contracts_commit']}`
(`AllContractsHashes.json` sha256 `{meta['all_contracts_hashes_sha256'][:16]}…`),
forked at L1 block `{meta['l1']['forked_at_block']}` on chain `{meta['l1']['chain_id']}`.
Protocol version {', '.join(meta['protocol_version']['old']) or '?'} → {', '.join(meta['protocol_version']['new']) or '?'}.

`prepare/*.safe.json` hold the transactions to send, `to`/`value`/`data` as-is —
the CREATE2 init code inside them IS the bytecode that was compiled for this
bundle. Broadcasting them deploys exactly that bytecode to exactly the addresses
`ecosystem.toml` names. Do NOT regenerate to "refresh" the bundle: a different
build environment yields different metadata, hence different addresses.

| File | What |
|---|---|
| `prepare/manifest.json` | bundle list, in execution order, with each bundle's signer (`target`) |
| `prepare/*.safe.json` | the calls themselves (Safe Transaction Builder shape) |
| `ecosystem.toml` | resulting addresses + governance stage 0/1/2 calldata |
| `bundle-metadata.json` | provenance + SHA-256 for every executable/supporting file |
| `extra-verification-logs.txt` | `forge verify-contract` commands (constructor args included) |

## Who signs what

Deployer (`{meta['deployer_address']}`) — broadcast these:
{chr(10).join(f'  - `{f}`' for f in deployer_files) or '  (none)'}

Governance / other signers — NOT for the deployer; they are the ceremony bundles
executed by their own multisig:
{chr(10).join(f'  - `{f}` (target `{t}`)' for t, f in other) or '  (none)'}

## Deploy for real

**The broadcasting EOA must be `{meta['deployer_address']}`.** The deployer is not a
free parameter: it is baked into the init code of {len(deployer_dependent)} deployment(s),
so a different signer puts them at different CREATE2 addresses while
`ecosystem.toml` and the governance calldata still name these ones —
{chr(10).join(f'  - `{d["address"]}`  {d["contract"]}' for d in deployer_dependent) or '  (none in this bundle)'}

```bash
git checkout {meta['contracts_commit']}        # bytecode identity: must match
cd protocol-ops && cargo build --release && cd ..

./l1-contracts/test/anvil-interop/replay-bundle-and-verify.sh \\
  --bundle <this-dir> --rpc <l1-rpc> --key "$DEPLOYER_KEY"
```

The wrapper verifies every bundle digest and the checkout's bytecode identity,
then passes `--skip-unkeyed` so only the deployer bundles are sent (the governance
bundles remain for their ceremony). It appends every mined hash to
`replay/transactions.txt` for PUVT. The broadcast is idempotent: CREATE2 deploys
already on-chain are skipped, so a re-run after a partial deploy resumes.

## Rehearse + verify (PUVT) locally, no compiler needed

```bash
./l1-contracts/test/anvil-interop/replay-bundle-and-verify.sh \\
  --bundle <this-dir> --fork-url <l1-rpc>
```

That forks L1 at block `{meta['l1']['forked_at_block']}`, funds the bundle
signers, replays every bundle under impersonation, and runs
`ecosystem verify-upgrade` against the result. Pass `--rpc <url>` instead of
`--fork-url` to verify an already-deployed chain.

## The calls, in execution order

Bundles are sent in `index` order and each bundle's transactions in listed order.
`data` is authoritative in the JSON; the sizes below are just for orientation.
{chr(10).join(calls_md)}
"""
open(f"{bundle}/README.md", "w").write(readme)
PY

# Catch an incomplete or internally inconsistent handoff before it can be
# uploaded, replayed or broadcast.
verify_bundle_integrity "$BUNDLE"

echo "=== Deploy bundle packed: $BUNDLE"
ls -1 "$BUNDLE" "$BUNDLE/prepare" | sed 's/^/  /'
