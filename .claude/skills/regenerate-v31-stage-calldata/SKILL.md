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

- `l1-contracts/test/anvil-interop/regen-and-verify-stage.sh` — wraps prepare
  → fork-broadcast → PUVT in one script.
- `l1-contracts/test/anvil-interop/broadcast-deployer-bundle-to-sepolia.ts` —
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
- For Option A (Docker): a built image tag at
  `ghcr.io/matter-labs/protocol-ops:<tag>`.

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
The wrapper script `regen-and-verify-stage.sh` currently bundles **1 + 1.5**
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

The current `broadcast-deployer-bundle-to-sepolia.ts` only handles the
deployer-signed bundles (phase 2). The per-CTM-admin bundles (phase 2b)
must be pushed separately, one for each admin EOA in the manifest
(`prepare/*_0x<admin-lc>.safe.json`). The local sim (phase 3.5) is what
catches a missing phase 2b — see the troubleshooting table below.

| Phase   | What runs                                                                                    | Touches real chain?      | Output                                                                                                                                                             |
| ------- | -------------------------------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1**   | `protocol_ops ecosystem upgrade-prepare-all` (deterministic from `stage.toml`)               | no                       | `output/stage/ecosystem.toml` + `manifest.json` + `*.safe.json`                                                                                                    |
| **1.5** | anvil fork + replay prepare bundles via impersonation + `protocol_ops verify-upgrade` (PUVT) | no                       | `executed.json` (fork-replay log), PUVT report                                                                                                                     |
| **2**   | `broadcast-deployer-bundle-to-sepolia.ts` — push CREATE2 deploys to **real Sepolia**         | yes (deployer EOA)       | bytecode lives at the CREATE2 addresses on real Sepolia                                                                                                            |
| **2b**  | broadcast **per-CTM admin** setup bundles (`*_0x343ee72…safe.json`, `*_0xd66949…safe.json`)  | yes (each CTM admin EOA) | `transferOwnership(PUH)`, `addVerifier`, `setNewVersionUpgrade`, ServerNotifier `ProxyAdmin.upgrade` land on Sepolia so stage1 `acceptOwnership` etc. don't revert |
| **3**   | `protocol_ops ecosystem governance-toml-to-simulator`                                        | no                       | tx-simulator scenario JSON (one entry per PUH stage 0/1/2 call)                                                                                                    |
| **3.5** | `yarn simulate --file <sim.json>` from a local `transaction-simulator` clone                 | no (forks Sepolia)       | local pass/fail before pushing — same code path as tx-simulator CI                                                                                                 |

Phase boundaries matter for state contamination: each broadcast in phase 2
diverges real Sepolia from the fork state phase 1.5 used as its baseline.
The fix is to rotate CREATE2 salts before the next regen — see the pre-flight
section below.

## Option A — Docker (preferred)

`docker/protocol/Dockerfile` builds a runtime image with `forge`, `cast`,
`anvil`, `protocol_ops`, `node`, and all compiled contract artifacts under
`/contracts/`. Trigger a fresh build, then run the wrapper scripts inside
the container with `/contracts/.../output/` bind-mounted from the host.

### Pre-flight: rotate CREATE2 salts when re-running against contaminated state

The biggest footgun: `regen-and-verify-stage.sh` forks **current Sepolia tip**,
and Sepolia state diverges every time you broadcast deployer-setup bundles
(steps 4 below: `addVerifier`, `transferOwnership`, ChainTypeManager init,
ServerNotifier ProxyAdmin upgrade, etc.). The prepare's Solidity isn't
idempotent against that state, so subsequent regens revert with
`AddressAlreadySet(...)`, `OperationMustBePending()`, or `Ownable: caller is
not the new owner` depending on which step the chain has already moved past.

Symptom-to-cause map:

| Revert in prepare                              | What's already on chain                                             |
| ---------------------------------------------- | ------------------------------------------------------------------- |
| `AddressAlreadySet(<verifier-addr>)`           | `ZKsyncOSDualVerifier.addVerifier(version, fflonk, plonk)` ran      |
| `OperationMustBePending()` on `executeInstant` | the legacy-Gov ceremony already ran (op is Done)                    |
| `OperationExists()` on `scheduleTransparent`   | the legacy-Gov ceremony is scheduled (Pending) but not yet executed |
| `Ownable2Step: caller is not the new owner`    | `transferOwnership(PUH)` didn't run on chain (or already accepted)  |

**Fix**: mint **fresh CREATE2 salts** in
`l1-contracts/upgrade-envs/v0.31.0-interopB/stage.toml` so the new prepare
deploys _new_ contracts (DualVerifier, ChainTypeManager impl, ServerNotifier,
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
mid-broadcast (i.e. between `regen-and-verify-stage.sh` and
`broadcast-deployer-bundle-to-sepolia.ts`) — the broadcast script reads the
fresh salts from the freshly-emitted prepare output.

### Run the regen

```bash
# 0. Build (or pull) an image for your branch. Manual dispatch lets you
#    pick a predictable tag via image_tag_override.
gh workflow run build-docker.yaml \
  --ref <branch> \
  -f image_tag_override=<branch>-regen
gh run watch
# Pulling on arm64 hosts: the image is built linux/amd64 only and runs under
# qemu emulation (1.5-3× slower than native). Add --platform linux/amd64 to
# `docker pull` and `docker run` calls.
docker pull --platform linux/amd64 ghcr.io/matter-labs/protocol-ops:<branch>-regen

# 1+2. Regen prepare/* + PUVT inside the container, writing directly to
#      the tracked path on the host via a bind mount.
#
#      Three bind mounts matter:
#        1. l1-contracts/test/anvil-interop  (ro) — so script fixes in your
#           working tree override the image's snapshot
#        2. l1-contracts/upgrade-envs/.../stage.toml (ro) — so salt rotations
#           and any other env edits go through
#        3. l1-contracts/upgrade-envs/.../output (rw) — so regen output
#           persists on the host for the commit step
docker run --rm --platform linux/amd64 \
  -e DEPLOYER_PK="$(tr -d '[:space:]' < ~/.test_pk)" \
  -e L1_FORK_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
  -v "$PWD/contracts/l1-contracts/test/anvil-interop:/contracts/l1-contracts/test/anvil-interop:ro" \
  -v "$PWD/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/stage.toml:/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/stage.toml:ro" \
  -v "$PWD/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output:/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output" \
  -w /contracts/l1-contracts \
  ghcr.io/matter-labs/protocol-ops:<branch>-regen \
  bash test/anvil-interop/regen-and-verify-stage.sh

# 3. Promote regen output to tracked path, regenerate every CI-checked
#    derived artifact on the host, commit. These checks run outside Docker
#    so the yarn/foundry workspaces need a real local checkout.
cd contracts
cp l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/ecosystem.toml \
   l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml
yarn lint:sol --fix --noPrompt && yarn lint:ts --fix && yarn prettier:fix
cd l1-contracts && yarn selectors --fix && ts-node scripts/copy-to-zkstack-out.ts
cd .. && yarn calculate-hashes:fix
cd protocol-ops && cargo +stable fmt && cd ..  # CI uses stable; nightly fmt produces drift
git add l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
        l1-contracts/selectors l1-contracts/zkstack-out AllContractsHashes.json
git commit -m "Regenerate v31 stage calldata"

# 4. Broadcast CREATE2 deploys to real Sepolia (idempotent — pre-filters
#    against on-chain `eth_getCode`).
docker run --rm \
  -e DEPLOYER_PK="$(tr -d '[:space:]' < ~/.test_pk)" \
  -e L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
  -v "$PWD/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output:/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output" \
  -w /contracts/l1-contracts \
  ghcr.io/matter-labs/protocol-ops:<branch>-regen \
  yarn --cwd test/anvil-interop ts-node broadcast-deployer-bundle-to-sepolia.ts

# 5. Emit the matching tx-simulator scenario. Only the governance ceremony
#    — phase 2 must already be done so the fork has the deployer's contracts.
docker run --rm \
  -v "$PWD/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output:/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output" \
  -v "$PWD/transaction-simulator/transactions:/out" \
  -w /contracts \
  ghcr.io/matter-labs/protocol-ops:<branch>-regen \
  protocol_ops ecosystem governance-toml-to-simulator \
    --env stage \
    --governance-toml /contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
    --out /out/$(date +%F)-v31-interopB-stage.json

# 6. Rehearse locally before pushing — see "Phase 3.5" below.
```

## Option B — Local toolchain (no Docker)

```bash
# 0. Rebuild artifacts the prepare phase reads.
cd contracts
yarn sc build:foundry                       # zkout/ — genesis hashes
cd l1-contracts && forge build              # out/  — l1 artifacts
cd ../protocol-ops && cargo build           # target/debug/protocol_ops

# 1. Regen against a Sepolia fork. Writes prepare/* + executed.json under
#    upgrade-envs/v0.31.0-interopB/output/stage/regen/ and runs PUVT.
cd ../l1-contracts
DEPLOYER_PK_FILE=~/.test_pk \
L1_FORK_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
bash test/anvil-interop/regen-and-verify-stage.sh

# 2. Promote the regen output to the tracked path.
cp upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/ecosystem.toml \
   upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml

# 3. Regenerate every derived artifact CI checks, then commit (same as
#    Option A step 3 above).

# 4. Broadcast CREATE2 deploys to real Sepolia.
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
yarn --cwd test/anvil-interop ts-node broadcast-deployer-bundle-to-sepolia.ts

# 5. Emit the tx-simulator scenario (governance ceremony only).
cd protocol-ops
./target/debug/protocol_ops ecosystem governance-toml-to-simulator \
  --env stage \
  --governance-toml ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
  --out <transaction-simulator>/transactions/$(date +%F)-v31-interopB-stage.json

# 6. Rehearse locally before pushing — see "Phase 3.5" below.
```

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
| `EOA with non-empty calldata` on `stage0` `startTimer` or similar       | Phase 2 wasn't run after the most recent salt rotation. Re-run `broadcast-deployer-bundle-to-sepolia.ts`.                                                                                                                                        |
| `OperationMustBePending()` / `OperationExists()` on legacy Gov          | Stale sim JSON that still includes deployer/legacy-Gov bundles. Re-emit with a fresh `protocol_ops` build — the simulator emitter must not include manifest.                                                                                     |
| `DeadlineNotYetPassed()` on stage1                                      | `checkDeadline()` `timeIncrease` injection missed. Confirm `simulator.rs` `CHECK_DEADLINE_SELECTOR` matches the actual stage1 selector, or extend the list.                                                                                      |
| `Ownable: caller is not the owner` on a CTM call                        | Ownership ceremony for that CTM never landed on Sepolia. Either the legacy-Gov bundle wasn't broadcast or the wrong PUH address is in `stage.toml`.                                                                                              |
| `Ownable2Step: caller is not the new owner` on stage1 `acceptOwnership` | Phase 2b gap — the CTM admin EOA never broadcast its `transferOwnership(PUH)` setup. Grep `prepare/manifest.json` for the failing target address, find the bundle that contains the `0xf2fde38b` call, broadcast it from the matching admin key. |
| `AddressAlreadySet(...)`                                                | State contamination from prior broadcasts — rotate CREATE2 salts (pre-flight section above) and re-run from phase 1.                                                                                                                             |

## Iteration flags on `regen-and-verify-stage.sh`

| Flag               | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `SKIP_PREPARE=1`   | Reuse the existing `regen/prepare/` (skip step 1's forge scripts)   |
| `SKIP_BROADCAST=1` | Reuse `regen/executed.json` (skip funding + bundle replay)          |
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
