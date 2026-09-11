# Getting CI green

## Relevant files

- `.github/workflows/lint.yaml` — repository lint, error lint, formatting for all Rust crates, protocol-ops Clippy and tests, codespell, and typos.
- `.github/workflows/l1-contracts-ci.yaml` — DA/L1 builds and tests, verifier-generator checks, and coverage checks.
- `.github/workflows/pre-merge-checks.yaml` — generated ABI, genesis, hash, selector, and chain-state checks, with the aggregate `pre-merge-verified` gate.
- `.github/workflows/build-contract-artifacts.yaml` — reusable production build for pre-merge checks.
- `.github/actions/build-anvil-interop-artifacts/action.yaml` — shared deterministic build for snapshot generation and verification.
- `.github/workflows/l1-contracts-foundry-ci.yaml` — deploy-script compilation, contract-size checks, and deployment-script smoke tests.
- `.github/workflows/anvil-interop-ci.yaml` — interop tests and the v31 to v33 upgrade test.
- `.github/workflows/update-generated-artifacts.yaml` — manual workflow for regenerating artifacts on a same-repository PR.
- `.github/foundry-versions.env` — the Foundry pin used by CI and local regeneration.
- `package.json`, `l1-contracts/package.json`, and `da-contracts/package.json` — supported local commands.
- `AGENTS.md` — mandatory Foundry and Anvil cleanup rules.

## CI tiers

Builds, tests, and static checks run on every push, including draft PRs. The generated-artifact checks in `pre-merge-checks.yaml` run when a PR is ready for review and touches artifact-affecting paths. Require the aggregate `pre-merge-verified` job on the base branch.

Iterate on a draft PR, then regenerate artifacts once the code and tests are stable. The Anvil integration tests load committed snapshots, so they can exercise old bytecode until regeneration. Use `ANVIL_INTEROP_FRESH_DEPLOY=1` locally to test a genesis-affecting change against current sources.

For a same-repository PR, dispatch **Update All Generated Artifacts** before marking it ready for review. This includes ZKsync OS genesis regeneration. Fork PRs must regenerate locally; the workflow rejects fork heads.

Coverage compares combined Foundry and Anvil line coverage against the exact base commit. CI reuses a valid base report or generates it alongside the PR. Changes to helpers, comments, remappings, or coverage tooling do not block that comparison by themselves. Each revision uses its own test and coverage code, so review changes to measurement logic alongside the reported delta. Missing or invalid reports and coverage decreases still fail.

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

# `+1.91.1` overrides crate-local nightly toolchains to match CI.
for dir in protocol-ops tools/{upgrade-readiness-checker,verifier-gen,wallets-gen,zksync-os-genesis-gen}; do
  (cd "$dir" && cargo +1.91.1 fmt --check)
done

(
  cd protocol-ops
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

To reproduce the v31 to v33 upgrade job after `yarn build-all-contracts`:

```bash
(
  set -e
  cd l1-contracts/test/anvil-interop
  trap 'bash cleanup.sh' EXIT
  yarn install
  yarn ts-node run-upgrade-test.ts
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

For a same-repository PR, the **Update All Generated Artifacts** workflow updates hashes, `zkstack-out`, selectors, ZKsync OS genesis, and the selected Anvil fixture set.

The Anvil `state-generation-check` reconstructs the fixture set selected by `stateVersion` and compares it with the committed snapshots. If it reports drift, use the regeneration workflow; do not edit compressed state files manually.
