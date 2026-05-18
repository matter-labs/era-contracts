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

## Option A — Docker (preferred)

`docker/protocol/Dockerfile` builds a runtime image with `forge`, `cast`,
`anvil`, `protocol_ops`, `node`, and all compiled contract artifacts under
`/contracts/`. Trigger a fresh build, then run the wrapper scripts inside
the container with `/contracts/.../output/` bind-mounted from the host.

```bash
# 0. Build (or pull) an image for your branch. Manual dispatch lets you
#    pick a predictable tag via image_tag_override.
gh workflow run build-docker.yaml \
  --ref <branch> \
  -f image_tag_override=<branch>-regen
gh run watch
docker pull ghcr.io/matter-labs/protocol-ops:<branch>-regen

# 1+2. Regen prepare/* + PUVT inside the container, writing directly to
#      the tracked path on the host via a bind mount.
docker run --rm \
  -e DEPLOYER_PK="$(tr -d '[:space:]' < ~/.test_pk)" \
  -e L1_FORK_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
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
cd protocol-ops && cargo fmt && cd ..
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

| Check               | Fix command                                              |
| ------------------- | -------------------------------------------------------- |
| solhint / eslint    | `yarn lint:sol --fix --noPrompt && yarn lint:ts --fix`  |
| prettier            | `yarn prettier:fix`                                      |
| cargo fmt           | `cd protocol-ops && cargo fmt`                           |
| selectors file      | `cd l1-contracts && yarn selectors --fix`                |
| zkstack-out JSON    | `cd l1-contracts && ts-node scripts/copy-to-zkstack-out.ts` |
| AllContractsHashes  | `yarn calculate-hashes:fix`                              |
| codespell           | local prose fix to the file flagged in CI                |
