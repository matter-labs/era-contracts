---
name: regenerate-v31-stage-calldata
description: Use when regenerating the committed v31 stage upgrade calldata (`output/stage/ecosystem.toml`) and the matching transaction-simulator scenario. Covers Docker-image and from-source paths through the prepare -> fork-broadcast -> PUVT -> tx-simulator-emit cycle, plus the real-Sepolia CREATE2 broadcast that keeps the simulator's local fork in sync.
---

# Regenerate v31 stage calldata

Use this skill whenever contracts, upgrade scripts, or env config change and
the committed v31 stage artifact needs to be refreshed:

```
l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml
```

That single TOML carries the merged `[governance_calls]` (PUH stage 0/1/2 hex),
`[core]`, `[ctms.<flavor>]` (Era + ZKsyncOS), and `[new_gateway]` sections.
Reviewers diff it; downstream tools (PUVT, the simulator converter) read it.

## Relevant files

- `l1-contracts/test/anvil-interop/regen-upgrade-calldata.sh` — wraps prepare
  → fork-broadcast → PUVT in one script.
- `l1-contracts/test/anvil-interop/yarn ts-node scripts/regen-via-docker.ts broadcast` —
  idempotent CREATE2 broadcaster that pre-filters against on-chain `eth_getCode`.
- `protocol-ops/src/commands/ecosystem/simulator.rs` — `governance-toml-to-simulator`.
  Emits **only** the governance ceremony (PUH stages 0/1/2). No deployer
  bundles: those land on real Sepolia in phase 2 and the sim's fork
  inherits them. Also injects `timeIncrease` for `checkDeadline()` so the
  fork clears the `GovernanceUpgradeTimer` gate.
- The local-rehearsal harness in the `transaction-simulator` repo
  (`yarn simulate --file <path>`). Phase 3.5 below uses it to validate
  every sim JSON before pushing — CI runs the exact same code.
- `docker/protocol/Dockerfile` + `.github/workflows/build-docker.yaml` —
  publishes `ghcr.io/matter-labs/protocol-ops:<tag>`.
- `protocol-ops/README.md` — `--help` reference for every protocol-ops command
  this skill invokes.
- `docs/ai-review/docs/ci-green.md` — order of CI checks that need refreshing after
  step 3 below (`solhint`, `eslint`, `prettier`, `cargo fmt`, `selectors`,
  `zkstack-out`, `AllContractsHashes.json`, `codespell`).

## Inputs

- A Sepolia L1 RPC URL (`L1_FORK_URL` / `L1_RPC_URL`).
- The deployer EOA's private key (`DEPLOYER_PK` or `DEPLOYER_PK_FILE`). The
  deployer's `owner_address` is governance (PUH on stage/mainnet) which is a
  contract — pass an EOA the deployer bundle's signer matches.
- A `ghcr.io/matter-labs/protocol-ops:<tag>` image (use the default
  `v31-camp-split` or trigger `build-docker.yaml` for a fresh tag).
- Mode 1 (local Rust) needs no host cross-toolchain — the build happens
  inside `ghcr.io/matter-labs/protocol-ops-base:latest`. See "How to run"
  below.

## Core principle: split senders by key custody

Every tx in a regen has a sender. There are exactly two camps:

- **Camp A — we hold the key.** Their work goes to **real Sepolia in phase 2**
  and never enters the sim JSON. The sim's fork forks Sepolia tip, so it
  inherits the post-state for free. (Examples today: the deployer EOA.
  Bundle 01/03's legacy-Gov `scheduleTransparent`+`executeInstant` pair is
  also Camp A — the deployer signs and broadcasts those.)
- **Camp B — we don't hold the key.** Their work goes into the **sim JSON
  with `from = bundle.target`**; the sim impersonates them via
  `hardhat_impersonateAccount`. (Examples today: per-CTM admin EOAs.)

**The rule**: never put a Camp-A bundle's txs into the sim JSON. Re-running
sender work that already happened on chain hits one of:

- `OperationExists()` / `OperationMustBePending()` for legacy-Gov ceremonies,
- `Ownable: caller is not the new owner` for an Ownable2Step `acceptOwnership`
  whose `transferOwnership` already cleared,
- `AddressAlreadySet(...)` for deploys whose target has code.

The fix is structural — execute all Camp-A work on real chain _before_ the
sim runs. Filters in `simulator.rs` should select by **signer**, not by
selector or `to`. Per-call selector skips (the old `SKIPPED_SELECTORS`,
CREATE2-factory carveout, etc.) are signal that we're encoding a Camp-A bundle
into Camp B — that's the bug, fix the camp assignment.

**Corollary for legacy Gov ceremonies**: the legacy-Gov op id is content-
addressed (`hash(targets, values, calldatas, predecessor, salt)`). Two regens
that touch the same targets with `salt = bytes32(0)` (today's hardcoded value
in `Utils.executeCalls`) produce the same op id, so the second regen's
broadcast collides with chain memory. Rotate the legacy-Gov salt per regen
alongside the CREATE2 salts so each broadcast lands cleanly.

## Phases

Mental model — each phase has one job and produces one canonical artifact.
The wrapper script `regen-upgrade-calldata.sh` currently bundles **1 + 1.5**
together; phases **2**, **3**, and **3.5** are explicit follow-up scripts.

**Ordering rule**: phases 2 + 2b **must** run before phase 3. The sim JSON
contains only the governance ceremony — every deployer-side and CTM-admin-side
setup tx is expected to already be on Sepolia tip so the fork inherits the
effect. Running phase 3 against a Sepolia where the setup hasn't landed
fails with one of:

- `EOA with non-empty calldata` — a CREATE2 target lacks code (phase 2 gap).
- `Ownable2Step: caller is not the new owner` on stage1 `acceptOwnership` —
  the CTM admin never ran `transferOwnership(PUH)` (phase 2b gap).
- `AddressAlreadySet(...)` — state contamination from a prior partial
  broadcast; rotate salts (pre-flight section below).

The current `yarn ts-node scripts/regen-via-docker.ts broadcast` only handles the
deployer-signed bundles (phase 2). The per-CTM-admin bundles (phase 2b)
must be pushed separately, one for each admin EOA in the manifest
(`prepare/*_0x<admin-lc>.safe.json`). The local sim (phase 3.5) is what
catches a missing phase 2b — see the troubleshooting table below.

| Phase   | What runs                                                                                       | Touches real chain?      | Output                                                                                                                                                             |
| ------- | ----------------------------------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1**   | `protocol_ops ecosystem upgrade-prepare-all` (deterministic from `stage.toml`)                  | no                       | `output/stage/ecosystem.toml` + `manifest.json` + `*.safe.json`                                                                                                    |
| **1.5** | anvil fork + replay prepare bundles via impersonation + `protocol_ops verify-upgrade` (PUVT)    | no                       | `executed.json` (fork-replay log), PUVT report                                                                                                                     |
| **2**   | `yarn ts-node scripts/regen-via-docker.ts broadcast` — push CREATE2 deploys to **real Sepolia** | yes (deployer EOA)       | bytecode lives at the CREATE2 addresses on real Sepolia                                                                                                            |
| **2b**  | broadcast **per-CTM admin** setup bundles (`*_0x343ee72…safe.json`, `*_0xd66949…safe.json`)     | yes (each CTM admin EOA) | `transferOwnership(PUH)`, `addVerifier`, `setNewVersionUpgrade`, ServerNotifier `ProxyAdmin.upgrade` land on Sepolia so stage1 `acceptOwnership` etc. don't revert |
| **3**   | `protocol_ops ecosystem governance-toml-to-simulator`                                           | no                       | tx-simulator scenario JSON (one entry per PUH stage 0/1/2 call)                                                                                                    |
| **3.5** | `yarn simulate --file <sim.json>` from a local `transaction-simulator` clone                    | no (forks Sepolia)       | local pass/fail before pushing — same code path as tx-simulator CI                                                                                                 |

Phase boundaries matter for state contamination: each broadcast in phase 2
diverges real Sepolia from the fork state phase 1.5 used as its baseline.
The fix is to rotate CREATE2 salts before the next regen — see the pre-flight
section below.

## How to run — Docker on macOS, native or Docker on Linux

> **On Linux, the native (no-Docker) path is preferred.** Run `protocol_ops`
> and Foundry directly against the host toolchain — the host is linux/amd64,
> so artifacts are already bit-identical to the image and Docker adds nothing
> but overhead. Docker is only required on macOS, where macOS-built Foundry
> artifacts diverge from Linux ones enough to break reproducibility.

Every regen, broadcast, and sim-emit step runs inside the published image so
Foundry + Solidity artifacts are bit-identical run-to-run. **On macOS, Docker
is required** — macOS-built Foundry artifacts diverge from Linux ones just
enough to break reproducibility. **On Linux you can skip Docker entirely**
and run `protocol_ops` and Foundry directly against the host toolchain
(produces the same bit-identical artifacts as the image since the image is
itself linux/amd64); the Docker path still works and is what CI uses but is
not needed on Linux.

### Native Linux path (preferred on Linux)

**Host build prerequisites** (one-time): `protocol_ops` links OpenSSL via the
`openssl-sys` crate, which needs `pkg-config` plus the OpenSSL dev headers on
the host. Without `pkg-config` the build fails with
`could not find system library 'openssl' … pkg-config could not be found`,
and — because `regen-upgrade-calldata.sh` silently falls back to a stale
`target/debug/protocol_ops` — the regen then runs old code (e.g. missing the
`CREATE2_SALT_GOV` env var) instead of erroring. Install once:

```bash
sudo apt-get install -y pkg-config libssl-dev
```

After any `protocol-ops/` Rust change (or a fresh contracts pull that touches
it), **rebuild and verify the binary actually recompiled** before regenerating
— a failed/stale build is the trap above:

```bash
cd protocol-ops && cargo build --bin protocol_ops
ls -la target/debug/protocol_ops   # mtime must be now, not an old date
```

Skip `regen-via-docker.ts` entirely. Use the wrapper script and host-native
`protocol_ops` for each phase:

```bash
cd l1-contracts/test/anvil-interop

# phases 1 + 1.5 — prepare + fork-replay + PUVT, no Docker
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
./regen-upgrade-calldata.sh stage

# phase 2 — broadcast the deployer's Camp-A bundles to REAL Sepolia (see below)
# phase 3 — emit tx-simulator JSON via `protocol_ops ecosystem governance-toml-to-simulator`
# phase 3.5 — `yarn --cwd ../../../transaction-simulator simulate --file <json>`
```

Build the host binary once with `cd protocol-ops && cargo build --release`
(the `regen-via-docker.ts` Mode-1 cross-build into `target-linux/` is only
needed when the host is macOS).

#### Phase 2 — deploy contracts to real Sepolia (native)

`upgrade-broadcast` requires a `--key` per **distinct signer** in the manifest
and bails otherwise. We only hold the **deployer** key (`~/.test_pk`,
`0x343Ee72…`); the Camp-B per-CTM admin signers (`0x5555…`, `0xd669…`) are
sim-only by design. So filter the manifest to the deployer-signed bundles
first, then broadcast just those. The broadcast is **idempotent** — `execute-safe`
skips CREATE2 targets that already have code and known `AddressAlreadySet`
reverts — so it's safe to re-run.

```bash
ENVOUT=l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage
DEP=0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7

# 1) Filter manifest → deployer-only (the .safe.json bundle files are reused as-is).
python3 - "$ENVOUT/prepare/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p))
dep="0x343ee72ddd8ccd80cd43d6adbc6c463a2de433a7"
m["bundles"]=[b for b in m["bundles"] if b["target"].lower()==dep]
json.dump(m, open(p.replace("manifest.json","manifest-deployer-only.json"),"w"), indent=2)
PY

# 2) Broadcast to real Sepolia. `--out`'s parent dir is the committed stage
#    dir, so the real deploy tx hashes append to the tracked transactions.txt
#    (the real-network log). New gov/CTM contracts deploy; already-on-chain
#    ones are skipped.
protocol_ops ecosystem upgrade-broadcast \
  --manifest "$ENVOUT/prepare/manifest-deployer-only.json" \
  --l1-rpc-url "$L1_RPC_URL" \
  --key "$DEP=$(cat ~/.test_pk)" \
  --out "$ENVOUT/sepolia-deploy-executed.json"

# 3) Sanity-check the new contracts now have code on real Sepolia:
#    cast code <new SecurityCouncil/Guardians/board addr> --rpc-url "$L1_RPC_URL"
```

Bundle 05 carries L1→L2 Gateway-CTM priority txs whose `mintValue` is paid in
the chain's ZK base token — the deployer EOA must hold enough of it
(`cast call <zkToken> "balanceOf(address)" $DEP`). Commit the grown
`transactions.txt` alongside the regen artifacts.

#### Phase 2.5 — verify the deployed contracts on Etherscan

After the real-Sepolia broadcast, source-verify every **newly deployed L1
contract** so the explorer shows source. For v31 stage that's the four
zk-governance contracts redeployed via CREATE2 (the L1→L2 Gateway-CTM
deploys in bundle 05 land on the **Gateway L2**, not Sepolia — verify those on
the Gateway explorer, not here). `upgrade-broadcast`'s `executed.json` has only
raw tx data, so get each contract's name + address + args from the **prepare's
forge broadcast log** (deterministic — fork CREATE2 addresses equal real
Sepolia's):

```
zk-governance/l1-contracts/broadcast/DeployPUHAndGuardians.s.sol/11155111/run-latest.json
era-contracts/l1-contracts/broadcast/CoreUpgrade_v31.s.sol/11155111/run-latest.json
```

For byte-exact constructor args, slice them off the on-chain initcode (the
deploy tx `data` = `salt(32) ++ creationCode ++ ctorArgs`; `ctorArgs =
data[2+64+len(creationCode):]`, where `creationCode = forge inspect
<src>:<C> bytecode`). That initcode starting with the locally-compiled
`creationCode` also proves the deployed bytecode matches the committed source.

Then, from the repo holding the source (zk-governance for the gov set), with
its `foundry.toml` compiler config:

```bash
forge verify-contract <addr> src/<C>.sol:<C> \
  --chain sepolia --compiler-version 0.8.24 \
  --num-of-optimizations 10000000 --evm-version cancun \
  --constructor-args 0x<ctorArgs> \
  --etherscan-api-key "$ETHERSCAN_API_KEY" --watch
```

v31 stage gov set (verify each): `TestnetProtocolUpgradeHandler`, `Guardians`,
`SecurityCouncil`, `EmergencyUpgradeBoard`. `already verified` is fine
(Etherscan bytecode-matches identical contracts). Verification is
Etherscan-side only — nothing to commit.

> **NOTE:** `regen-via-docker.ts` is hard-disabled on Linux (it `die()`s unless
> `FORCE_DOCKER_REGEN=1`). Everything above is the native replacement.

The Docker entry point is `scripts/regen-via-docker.ts` with two
binary-source modes:

| Mode                                                                                 | When                                                                  | What's mounted                                                  | Per-iteration cost                                            |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------- |
| **Mode 1 — Iteration**: local cross-built `protocol_ops` + bundled Foundry/contracts | Rust changes only (sim filter, emitter, broadcaster, prepare wrapper) | host binary → `/contracts/protocol-ops/protocol_ops` (override) | ~30 s cross-cargo + prepare time                              |
| **Mode 2 — Canonical**: everything from the image                                    | Solidity changed, or you're producing the final regen you commit/push | nothing overridden — image has everything                       | trigger `build-docker.yaml` (~12 min CI build) + prepare time |

Both modes use the same `stage.toml`, `permanent-values/`, and
`test/anvil-interop/` bind-mounts so config/script edits land without a
rebuild. Sourcify is blocked at the container level (`--add-host
sourcify.dev:127.0.0.1`) so forge's post-success `ExternalIdentifier` lookup
fails fast — foundry-zksync v0.1.5 silently ignores `--disable-labels` for
`forge script`, so this is currently the only way to keep prepare under 15
min per CTM.

### Mode 1 — local Rust + Docker contracts

No host cross-toolchain needed: `regen-via-docker.ts` cross-builds
`protocol_ops` by running `cargo build --release` inside the
`protocol-ops-base` image (which already has the right Rust nightly).
Output lands at `protocol-ops/target-linux/release/protocol_ops` (separate
from the host's macOS `target/`). A named Docker volume
(`protocol-ops-cargo-cache`) holds the crates registry/git cache between
runs, so subsequent builds are incremental (~30 s typical, ~5 min cold).

Per-iteration:

```bash
# phase 1 — regen against Sepolia fork (cross-builds protocol_ops first)
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
yarn ts-node scripts/regen-via-docker.ts regen

# phase 2 — broadcast Camp-A bundles to real Sepolia
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
yarn ts-node scripts/regen-via-docker.ts broadcast

# phase 3 — emit tx-simulator JSON
DEPLOYER_PK_FILE=~/.test_pk \
yarn ts-node scripts/regen-via-docker.ts sim-emit \
  ../transaction-simulator/transactions/$(date +%F)-v31-interopB-stage.json

# phase 3.5 — local rehearsal (host, not in docker)
SEPOLIA_RPC=$L1_RPC_URL \
yarn --cwd ../transaction-simulator simulate --file transactions/<dated>.json
```

Toggles:

| Env var                        | Effect                                                                                                                           |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `USE_BUNDLED_BIN=1`            | Skip the binary mount; use the image's bundled `protocol_ops` (drops the cross-build entirely — config/Solidity-only iteration). |
| `SKIP_BUILD=1`                 | Reuse `protocol-ops/target/x86_64-unknown-linux-gnu/release/protocol_ops` without re-running cargo zigbuild.                     |
| `PROTOCOL_OPS_BIN_HOST=<path>` | Mount this binary explicitly (skips cross-build).                                                                                |
| `PROTOCOL_OPS_IMAGE=<ref>`     | Override the default image ref (`ghcr.io/matter-labs/protocol-ops:v31-camp-split`).                                              |

### Mode 2 — canonical regen from a fresh image

When you're producing the final regen that you'll commit and push, build a
new image first (so the bundled `protocol_ops` is from a tagged commit, not
a developer's local cargo state). The Dockerfile under `docker/protocol/`
bundles `forge`, `cast`, `anvil`, `protocol_ops`, `node`, and all compiled
contract artifacts. After the workflow finishes, invoke the same
`scripts/regen-via-docker.ts` entry points with `USE_BUNDLED_BIN=1` so the
image's binary is used and no host cross-build runs.

### Pre-flight: rotate CREATE2 salts when re-running against contaminated state

The biggest footgun: `regen-upgrade-calldata.sh` forks **current Sepolia tip**,
and Sepolia state diverges every time you broadcast deployer-setup bundles
(steps 4 below: ChainTypeManager init, ServerNotifier ProxyAdmin upgrade,
etc.). The prepare's Solidity isn't
idempotent against that state, so subsequent regens revert with
`AddressAlreadySet(...)`, `OperationMustBePending()`, or `Ownable: caller is
not the new owner` depending on which step the chain has already moved past.

Symptom-to-cause map:

| Revert in prepare                              | What's already on chain                                             |
| ---------------------------------------------- | ------------------------------------------------------------------- |
| `OperationMustBePending()` on `executeInstant` | the legacy-Gov ceremony already ran (op is Done)                    |
| `OperationExists()` on `scheduleTransparent`   | the legacy-Gov ceremony is scheduled (Pending) but not yet executed |
| `Ownable2Step: caller is not the new owner`    | `transferOwnership(PUH)` didn't run on chain (or already accepted)  |

**Fix**: mint **fresh CREATE2 salts** in
`l1-contracts/upgrade-envs/v0.31.0-interopB/stage.toml` so the new prepare
deploys _new_ contracts (Verifier, ChainTypeManager impl, ServerNotifier,
…) that don't collide with the on-chain state of their predecessors.

```bash
# Generate three fresh 32-byte salts and paste them into stage.toml:
#   [contracts] create2_factory_salt = "0x…"         ← core
#   [create2_factory_salts]
#   "0x<Era CTM proxy>"      = "0x…"                 ← Era CTM
#   "0x<ZKsyncOS CTM proxy>" = "0x…"                 ← ZKsyncOS CTM
for i in 1 2 3; do python3 -c "import secrets; print('0x' + secrets.token_hex(32))"; done
```

Rotation is cheap — it just produces new deploy addresses; reviewers re-diff
the new `output/stage/ecosystem.toml` like any normal regen. Don't rotate
mid-broadcast (i.e. between `regen-upgrade-calldata.sh` and
`yarn ts-node scripts/regen-via-docker.ts broadcast`) — the broadcast script reads the
fresh salts from the freshly-emitted prepare output.

Build the image, then run the same three subcommands as Mode 1 with
`USE_BUNDLED_BIN=1`:

```bash
# 0. Build (or pull) the image. Manual dispatch lets you pick a predictable
#    tag via image_tag_override.
gh workflow run build-docker.yaml \
  --ref <branch> \
  -f image_tag_override=<branch>-regen
gh run watch
docker pull --platform linux/amd64 ghcr.io/matter-labs/protocol-ops:<branch>-regen

# 1. Phase 1 — regen against a Sepolia fork.
PROTOCOL_OPS_IMAGE=ghcr.io/matter-labs/protocol-ops:<branch>-regen \
USE_BUNDLED_BIN=1 \
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
yarn ts-node scripts/regen-via-docker.ts regen

# 2. Refresh CI-derived artifacts and commit (host tools — yarn/foundry).
yarn lint:sol --fix --noPrompt && yarn lint:ts --fix && yarn prettier:fix
cd l1-contracts && yarn selectors --fix && ts-node scripts/copy-to-zkstack-out.ts
cd .. && yarn calculate-hashes:fix
cd protocol-ops && cargo +stable fmt && cd ..  # CI uses stable; nightly fmt drifts
git add l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
        l1-contracts/selectors l1-contracts/zkstack-out AllContractsHashes.json
git commit -m "Regenerate v31 stage calldata"

# 3. Phase 2 — broadcast Camp-A bundles to real Sepolia.
PROTOCOL_OPS_IMAGE=ghcr.io/matter-labs/protocol-ops:<branch>-regen \
USE_BUNDLED_BIN=1 \
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
yarn ts-node scripts/regen-via-docker.ts broadcast

# 4. Phase 3 — emit tx-simulator JSON.
PROTOCOL_OPS_IMAGE=ghcr.io/matter-labs/protocol-ops:<branch>-regen \
USE_BUNDLED_BIN=1 \
DEPLOYER_PK_FILE=~/.test_pk \
yarn ts-node scripts/regen-via-docker.ts sim-emit \
  ../transaction-simulator/transactions/$(date +%F)-v31-interopB-stage.json

# 5. Phase 3.5 — local rehearsal (see below).
```

Notes:

- The image is published linux/amd64 only; arm64 Macs run it under qemu
  emulation (1.5–3× slower than native). The wrapper passes
  `--platform linux/amd64` automatically.
- `ecosystem.toml` is auto-promoted to its canonical tracked path by
  `upgrade-prepare-all` — no `cp` step needed in user workflow.

## Phase 3.5 — Rehearse the sim JSON locally before pushing

The tx-simulator CI runs `yarn simulate` against the JSON in `transactions/`.
Run the **same** command from a local clone before pushing — it forks Sepolia,
catches reverts in seconds, and saves a CI round-trip per iteration.

Prereqs: a clone of `matter-labs/transaction-simulator` somewhere local with
`yarn install` done. The skill assumes
`~/programming/zksync/transaction-simulator/` — adjust paths.

```bash
# 1. Drop the freshly-emitted JSON in the transactions/ directory.
cp <emitted-sim.json> ~/programming/zksync/transaction-simulator/transactions/$(date +%F)-v31-interopB-stage.json

# 2. Run the local simulator. Prints per-tx ✔/❌ as it goes.
cd ~/programming/zksync/transaction-simulator
yarn simulate --file transactions/$(date +%F)-v31-interopB-stage.json

# 3. On revert: read the console output + ./logs/<run>/ for the anvil trace.
#    For DeadlineNotYetPassed / "EOA with non-empty calldata" / OperationMustBePending
#    see the troubleshooting table below.

# 4. Only push to the tx-simulator branch once `✅ All simulations succeed!`
#    on a clean local run.
cd ~/programming/zksync/transaction-simulator
git checkout -b kl/v31-stage   # or reuse the existing one
git add transactions/$(date +%F)-v31-interopB-stage.json
# delete any older dated file for the same env so CI only validates the current one
git commit -m "Regenerate v31-interopB-stage sim"
git push
```

### Local-rehearsal troubleshooting

| Symptom in `yarn simulate` output                                       | Likely cause                                                                                                                                                                                                                                     |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `EOA with non-empty calldata` on `stage0` `startTimer` or similar       | Phase 2 wasn't run after the most recent salt rotation. Re-run `yarn ts-node scripts/regen-via-docker.ts broadcast`.                                                                                                                             |
| `OperationMustBePending()` / `OperationExists()` on legacy Gov          | Stale sim JSON that still includes deployer/legacy-Gov bundles. Re-emit with a fresh `protocol_ops` build — the simulator emitter must not include manifest.                                                                                     |
| `DeadlineNotYetPassed()` on stage1                                      | `checkDeadline()` `timeIncrease` injection missed. Confirm `simulator.rs` `CHECK_DEADLINE_SELECTOR` matches the actual stage1 selector, or extend the list.                                                                                      |
| `Ownable: caller is not the owner` on a CTM call                        | Ownership ceremony for that CTM never landed on Sepolia. Either the legacy-Gov bundle wasn't broadcast or the wrong PUH address is in `stage.toml`.                                                                                              |
| `Ownable2Step: caller is not the new owner` on stage1 `acceptOwnership` | Phase 2b gap — the CTM admin EOA never broadcast its `transferOwnership(PUH)` setup. Grep `prepare/manifest.json` for the failing target address, find the bundle that contains the `0xf2fde38b` call, broadcast it from the matching admin key. |
| `AddressAlreadySet(...)`                                                | State contamination from prior broadcasts — rotate CREATE2 salts (pre-flight section above) and re-run from phase 1.                                                                                                                             |

## Iteration flags on `regen-upgrade-calldata.sh`

| Flag               | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `SKIP_PREPARE=1`   | Reuse the existing `regen/prepare/` (skip step 1's forge scripts)   |
| `SKIP_REHEARSAL=1` | Reuse `regen/executed.json` (skip funding + bundle replay)          |
| `KEEP_ANVIL=1`     | Leave the fork anvil running on port 29545 for ad-hoc `cast` probes |

## CI checks gated by step 3

Anything missed here makes CI red. See `docs/ai-review/docs/ci-green.md` for the
full check ↔ workflow mapping.

| Check              | Fix command                                                 |
| ------------------ | ----------------------------------------------------------- |
| solhint / eslint   | `yarn lint:sol --fix --noPrompt && yarn lint:ts --fix`      |
| prettier           | `yarn prettier:fix`                                         |
| cargo fmt          | `cd protocol-ops && cargo +stable fmt`                      |
| selectors file     | `cd l1-contracts && yarn selectors --fix`                   |
| zkstack-out JSON   | `cd l1-contracts && ts-node scripts/copy-to-zkstack-out.ts` |
| AllContractsHashes | `yarn calculate-hashes:fix`                                 |
| codespell          | local prose fix to the file flagged in CI                   |
