# Calldata Generation Workflows

Each `generate-*.yaml` workflow invokes a `protocol_ops` subcommand via
`protocol-ops.sh --tag <docker-tag>` (the wrapper forwards the rest of the
args to `protocol_ops` unless the first post-flag word is `forge`/`cast`).

## Mapping

| Workflow                                        | Entry point                                                             |
| ----------------------------------------------- | ----------------------------------------------------------------------- |
| `generate-chain-init-calldata`                  | `protocol-ops chain init`                                               |
| `generate-chain-upgrade-calldata`               | `protocol-ops chain upgrade`                                            |
| `generate-chain-set-upgrade-timestamp-calldata` | `protocol-ops chain set-upgrade-timestamp`                              |
| `generate-chain-add-validator-calldata`         | `protocol-ops chain add-validator`                                      |
| `generate-chain-remove-validator-calldata`      | `protocol-ops chain remove-validator`                                   |
| `generate-gateway-convert-calldata`             | `protocol-ops chain gateway convert`                                    |
| `generate-upgrade-calldata-prepare`             | `protocol-ops ecosystem upgrade-prepare`                                |
| `generate-upgrade-calldata-governance`          | `protocol-ops ecosystem upgrade-governance` (stages 0+1+2)              |
| `generate-migrate-to-gw-phase0-pause`           | `protocol-ops chain gateway migrate-to phase-0-pause-deposits`          |
| `generate-migrate-to-gw-phase1-submit`          | `protocol-ops chain gateway migrate-to phase-1-submit`                  |
| `generate-migrate-to-gw-phase2-finalize`        | `protocol-ops chain gateway migrate-to phase-2-finalize`                |
| `generate-migrate-to-gw-phase3-validators`      | `protocol-ops chain gateway migrate-to phase-3-validators`              |
| `generate-migrate-from-gw-phase0-pause`         | `protocol-ops chain gateway migrate-from phase-0-pause-deposits`        |
| `generate-migrate-from-gw-phase1-submit`        | `protocol-ops chain gateway migrate-from phase-1-submit`                |
| `generate-migrate-from-gw-phase2-finalize`      | `protocol-ops chain gateway migrate-from phase-2-finalize`              |
| `generate-migrate-from-gw-phase3-set-da`        | `protocol-ops chain gateway migrate-from phase-3-set-da-validator-pair` |

## Execute workflows

| Workflow                        | Purpose                                                                                                                                                                                                                                   |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `execute-deployer-safe-bundles` | Apply Safe bundles whose `target` is the ecosystem deployer EOA (bundles from the chain-init workflow, the upgrade-prepare workflow, and the migrate-to/from phase-2-finalize workflows). Signs with `DEPLOYER_PRIVATE_KEY_<env>` secret. |

## Conventions

- **All workflows** share: `environment`, `protocol_ops_tag`, `l1_rpc_url`
- **Integration-test-only** env vars (e.g. `L1_DIAMOND_CUT_DATA`) are NOT workflow inputs
- **v30-only** overrides are marked `[v30 only]` in descriptions and `TODO(v30-removal)` in code
- **Artifact names**:
  - per-chain workflows: `safe-bundles-{operation}-{chain_name}-{environment}`
  - ecosystem-wide workflows (`upgrade-prepare`, `upgrade-governance`): `safe-bundles-{operation}-{environment}` (no `chain_name`)

## CI tiers: per-commit vs pre-merge

PR CI is split into two tiers:

- **Per-commit** (`l1-contracts-ci`, `l1-contracts-foundry-ci`, `l2-contracts-ci`,
  `system-contracts-ci`, `anvil-interop-ci`, `lint`, `slither`, ...): builds,
  tests, and static checks that depend only on the source in the PR. The
  anvil-interop suite runs against a **fresh from-source deployment**
  (`ANVIL_INTEROP_FRESH_DEPLOY=1`), so it never depends on the committed
  chain-state snapshots.
- **Pre-merge** (`pre-merge-checks`): checks that validate committed
  _generated_ artifacts — `AllContractsHashes.json`, `l1-contracts/selectors`,
  `l1-contracts/zkstack-out`, and the anvil-interop chain-state snapshots
  (determinism gate + preloaded-state interop run). These fail whenever
  bytecode changes and are fixed by a regen + commit, so they would force a
  regeneration on every push if they ran per-commit.

Merge flow for a PR:

1. Iterate; per-commit CI must be green.
2. When ready to merge, dispatch **Update All Generated Artifacts** with the PR
   number — a single regen that commits hashes + selectors + zkstack-out, then
   the chain-state snapshots, to the PR branch.
3. Add the **`pre-merge`** label to the PR. `pre-merge-checks` runs on the
   labeled commit and on every later push while the label stays on; merge once
   it is green. (The workflow also runs unconditionally in a merge queue and
   via manual dispatch.)
