# Getting CI green

## Relevant files

- `.github/workflows/lint.yaml` — repository lint, error lint, protocol-ops formatting, Clippy and tests, codespell, and typos.
- `.github/workflows/l1-contracts-ci.yaml` — DA/L1 builds and tests, generated ABI, genesis, hash, selector, and coverage checks.
- `.github/workflows/l1-contracts-foundry-ci.yaml` — deploy-script compilation, contract-size checks, and deployment-script smoke tests.
- `.github/workflows/anvil-interop-ci.yaml` — interop tests, the v31 to v32 upgrade test, and chain-state determinism.
- `.github/workflows/update-generated-artifacts.yaml` — manual workflow for regenerating artifacts on a same-repository PR.
- `.github/foundry-versions.env` — the Foundry pin used by CI and local regeneration.
- `package.json`, `l1-contracts/package.json`, and `da-contracts/package.json` — supported local commands.
- `AGENTS.md` — mandatory Foundry and Anvil cleanup rules.

## Toolchain

Use the Node version from `.nvmrc` and upstream Foundry from `.github/foundry-versions.env`. Do not use foundry-zksync or `forge --zksync`.

To install the pinned Foundry release:

```bash
. .github/foundry-versions.env
foundryup --install "$FOUNDRY_VERSION"
```

## Core local checks

Run from the repository root:

```bash
yarn build-all-contracts
(cd l1-contracts && forge build deploy-scripts)

yarn l1 test:foundry
yarn da test:foundry

yarn lint:check
yarn l1 errors-lint --check

(
  cd protocol-ops
  cargo +1.91.1 fmt --check
  cargo +1.91.1 clippy --all-targets -- -D warnings
  cargo +1.91.1 test --all-targets
)
```

`codespell` and `typos` run as separate CI jobs and are not included in `yarn lint:check`.

## Anvil interop checks

To reproduce the fast preloaded-state job:

```bash
yarn l1 build:anvil-interop-dev-artifacts

(
  set -e
  cd l1-contracts/test/anvil-interop
  trap 'bash cleanup.sh' EXIT
  yarn install
  yarn tsc --noEmit
  yarn test:unit
  ANVIL_INTEROP_MAX_PARALLEL_WORKERS=4 yarn ts-node run-hardhat-interop-test.ts
)
```

To reproduce the v31 to v32 upgrade job after `yarn build-all-contracts`:

```bash
(
  set -e
  cd l1-contracts/test/anvil-interop
  trap 'bash cleanup.sh' EXIT
  yarn install
  yarn ts-node run-v31-to-v32-upgrade-test.ts
)
```

The upgrade harness invokes `protocol-ops.sh`, which builds `protocol_ops` when needed. It uses upstream Foundry.

Never use `pkill`, `killall`, or another blanket Anvil kill command. Always run `l1-contracts/test/anvil-interop/cleanup.sh`.

## Generated artifacts

Regenerate artifacts only after code and tests are stable. With the pinned Foundry release, run:

```bash
./recompute_hashes.sh
yarn l1 selectors --fix
```

The first command rebuilds DA and L1 contracts, refreshes `l1-contracts/zkstack-out/`, and updates `AllContractsHashes.json`. The second refreshes `l1-contracts/selectors` from that build.

Read-only checks are:

```bash
yarn calculate-hashes:check
yarn l1 selectors --check
```

CI also regenerates `configs/genesis/zksync-os/latest.json`. On Linux, after building with the pinned Foundry release, reproduce that check with:

```bash
(
  cd tools/zksync-os-genesis-gen
  cargo run --locked --release --bin zksync-os-genesis-gen -- \
    --output-file ../../configs/genesis/zksync-os/latest.json
)
```

For a same-repository PR, the **Update All Generated Artifacts** workflow updates hashes, `zkstack-out`, selectors, and the selected Anvil fixture set. It does not regenerate the ZKsync OS genesis file.

The Anvil `state-generation-check` reconstructs the fixture set selected by `stateVersion` and compares it with the committed snapshots. If it reports drift, use the regeneration workflow; do not edit compressed state files manually.
