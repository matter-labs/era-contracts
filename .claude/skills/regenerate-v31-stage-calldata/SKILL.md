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
- `l1-contracts/test/anvil-interop/broadcast-deployer-bundle-to-sepolia.sh` —
  idempotent CREATE2 broadcaster that pre-filters against on-chain `eth_getCode`.
- `protocol-ops/src/commands/ecosystem/simulator.rs` — `governance-toml-to-simulator`
  with `--include-manifest`, the deployer-bundle CREATE2-only filter, the
  `scheduleTransparent`/ZK-approve/GW-priority skip list, and the
  `checkDeadline()` `timeIncrease` injection.
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

## Phases

Mental model — each phase has one job and produces one canonical artifact.
The wrapper script `regen-and-verify-stage.sh` currently bundles **1 + 1.5**
together; phases **2** and **3** are explicit follow-up scripts. Phase **1.5**
is the only rehearsal step we run — phase **3**'s tx-simulator CI doubles as
the post-broadcast rehearsal, so no need to duplicate.

| Phase   | What runs                                                                                    | Touches real chain? | Output                                                            |
| ------- | -------------------------------------------------------------------------------------------- | ------------------- | ----------------------------------------------------------------- |
| **1**   | `protocol_ops ecosystem upgrade-prepare-all` (deterministic from `stage.toml`)               | no                  | `output/stage/ecosystem.toml` + `manifest.json` + `*.safe.json`   |
| **1.5** | anvil fork + replay prepare bundles via impersonation + `protocol_ops verify-upgrade` (PUVT) | no                  | `executed.json` (fork-replay log), PUVT report                    |
| **2**   | `broadcast-deployer-bundle-to-sepolia.sh` — push CREATE2 deploys to **real Sepolia**         | yes (deployer EOA)  | bytecode lives at the CREATE2 addresses on real Sepolia           |
| **3**   | `protocol_ops ecosystem governance-toml-to-simulator --include-manifest`                     | no                  | tx-simulator scenario JSON (push to `transaction-simulator` repo) |

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
`broadcast-deployer-bundle-to-sepolia.sh`) — the broadcast script reads the
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
  bash test/anvil-interop/broadcast-deployer-bundle-to-sepolia.sh

# 5. Emit the matching tx-simulator scenario.
docker run --rm \
  -v "$PWD/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output:/contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output" \
  -v "$PWD/transaction-simulator/transactions:/out" \
  -w /contracts \
  ghcr.io/matter-labs/protocol-ops:<branch>-regen \
  protocol_ops ecosystem governance-toml-to-simulator \
    --env stage \
    --governance-toml /contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
    --include-manifest /contracts/l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/manifest.json \
    --out /out/$(date +%F)-v31-interopB-stage.json
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
bash test/anvil-interop/broadcast-deployer-bundle-to-sepolia.sh

# 5. Emit the tx-simulator scenario.
cd protocol-ops
./target/debug/protocol_ops ecosystem governance-toml-to-simulator \
  --env stage \
  --governance-toml ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
  --include-manifest ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/manifest.json \
  --out <transaction-simulator>/transactions/$(date +%F)-v31-interopB-stage.json
```

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
