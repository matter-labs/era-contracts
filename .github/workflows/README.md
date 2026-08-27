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

- **Per-commit** (`l1-contracts-ci`, `anvil-interop-ci`, `lint`, `slither`, ...):
  builds, tests, and static checks that depend only on the PR's source. The
  anvil-interop suite runs a fresh from-source deployment
  (`ANVIL_INTEROP_FRESH_DEPLOY=1`), so it never depends on committed snapshots.
- **Pre-merge** (`pre-merge-checks`): checks of committed _generated_ artifacts —
  `AllContractsHashes.json`, `l1-contracts/selectors`, `l1-contracts/zkstack-out`,
  and the anvil-interop chain-state snapshots (determinism gate +
  preloaded-state run). Any bytecode change invalidates these; the fix is a
  regen + commit, so they skip on **draft** PRs and run once the PR is ready
  for review (and on every later push while it stays non-draft; also
  unconditionally on merge queue / manual dispatch).

Merge flow: iterate on a draft PR until per-commit CI is green → dispatch
**Update All Generated Artifacts** with the PR number (a single regen that
commits hashes + selectors + zkstack-out, then chain states) → mark the PR
ready for review → merge once `pre-merge-checks` is green. If review forces
bytecode changes, regen again (or convert back to draft until done).
