# Calldata Generation Workflows

Each `generate-*.yaml` workflow invokes a `protocol_ops` subcommand via
`protocol-ops.sh --tag <docker-tag>` (the wrapper forwards the rest of the
args to `protocol_ops` unless the first post-flag word is `forge`/`cast`).

## Mapping

| Workflow                                        | Entry point                                                |
| ----------------------------------------------- | ---------------------------------------------------------- |
| `generate-chain-init-calldata`                  | `protocol-ops chain init`                                  |
| `generate-chain-upgrade-calldata`               | `protocol-ops chain upgrade`                               |
| `generate-chain-set-upgrade-timestamp-calldata` | `protocol-ops chain set-upgrade-timestamp`                 |
| `generate-chain-add-validator-calldata`         | `protocol-ops chain add-validator`                         |
| `generate-chain-remove-validator-calldata`      | `protocol-ops chain remove-validator`                      |
| `generate-upgrade-calldata-prepare`             | `protocol-ops ecosystem upgrade-prepare-all`               |
| `generate-upgrade-calldata-governance`          | `protocol-ops ecosystem upgrade-governance` (stages 0+1+2) |

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

## CI tiers

PR CI is split into a per-commit tier and a pre-merge tier (the committed-generated-artifact
checks, skipped while a PR is a draft). That split, and the one-dispatch regen that clears it,
are documented in [docs/ai-review/docs/ci-green.md](../../docs/ai-review/docs/ci-green.md).
