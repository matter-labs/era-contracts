# Calldata Generation Workflows

Each `generate-*.yaml` workflow invokes a `protocol_ops` subcommand inside a released
`ghcr.io/matter-labs/protocol-ops` image, via `protocol-ops.sh --tag <docker-tag>` (the wrapper
forwards the rest of the args to `protocol_ops` unless the first post-flag word is `forge`/`cast`).
Nothing is compiled per run: the image is what gets released and tested.

## Release flow

1. Merge the PRs that change the upgrade's scripts and inputs (`l1-contracts/upgrade-envs/<upgrade>/`,
   `AllContractsHashes.json`, the chain states).
2. Test that commit with zksync-os-integration-tests: in a PR there, point `protocol_ops` and
   `zksync_os_genesis_gen` in its `Cargo.toml` at the commit (`rev = "<commit>"`). That PR's passed
   `integration-tests.yaml` run is the one the release cites.
3. Release the image:
   `gh workflow run build-docker.yaml --ref <release branch> -f ref=<commit> -f integration_tests_run_id=<that run's id>`,
   plus `-f zk_governance_commit=<sha>` when the governance redeploy needs a zk-governance commit other
   than the Dockerfile's `ZK_GOVERNANCE_COMMIT`. `--ref` picks the copy of the workflow that runs, so
   use the release branch's. It refuses to push unless that run passed and its `Cargo.lock` pins its
   era-contracts crates at the commit. Before pushing, it checks the image's contract build against
   its `AllContractsHashes.json`, runs the generate, handoff and deploy commands through
   `protocol-ops.sh --tag` against the anvil-interop fixture (the previous release's chain states),
   then the governance calls and a partner's chain commands (`set-upgrade-timestamp`,
   `add-validator`) with `docker run`, as the partner guide does (`yarn test:release-flow` in `l1-contracts/test/anvil-interop`).
   The run summary gives the digest.
4. Pass `protocol_ops_tag=sha256:<digest>` to `generate-ecosystem-upgrade-calldata`, the chain
   workflows and `execute-deployer-safe-bundles`; `deploy-ecosystem-upgrade` runs the image its
   bundle names. Run it on `stage` first, then `testnet` and `mainnet`. Partners (ADI) get the same
   digest only once our chain workflows have run it on `stage`, and run it with their own keys:
   [docs/protocol-ops-for-partners.md](../../docs/protocol-ops-for-partners.md).
5. Before each ecosystem's governance vote, mainnet's included, run
   [phase 3](../../protocol-docs/ecosystem-upgrade.md#3-verify) against its L1: `verify-bootstrap` on
   the deployment, in the same image, and the transaction simulator on a fork of that L1 with
   generate's `transaction-simulator.json` (the other signers' bundles, the governance call, the
   post-upgrade test calls). That is the rehearsal in the target's own state.

The calldata workflows refuse an image without the `org.opencontainers.image.revision` label
`build-docker` sets (such as those `build-and-push-docker` pushes). `protocol-ops.sh --tag` runs the
image's own configs and mounts only output directories from the checkout, so a change to
`upgrade-envs/` (salts, owners, presets) needs a new image. Our deployer keys serve only `stage`,
`testnet` and `mainnet`.

## Mapping

| Workflow                                        | Entry point                                |
| ----------------------------------------------- | ------------------------------------------ |
| `generate-chain-init-calldata`                  | `protocol-ops chain init`                  |
| `generate-chain-upgrade-calldata`               | `protocol-ops chain upgrade`               |
| `generate-chain-set-upgrade-timestamp-calldata` | `protocol-ops chain set-upgrade-timestamp` |
| `generate-chain-add-validator-calldata`         | `protocol-ops chain add-validator`         |
| `generate-chain-remove-validator-calldata`      | `protocol-ops chain remove-validator`      |

## Execute workflows

| Workflow                        | Purpose                                                                                                                                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `execute-deployer-safe-bundles` | Apply Safe bundles that all target the ecosystem deployer EOA (e.g. the chain-init workflow's, when the deployer signs all of them). Signs with the deployer secret of the environment's L1, `DEPLOYER_PRIVATE_KEY_SEPOLIA` or `_MAINNET`. |

## Ecosystem-upgrade workflows

| Workflow                              | Purpose                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `generate-ecosystem-upgrade-calldata` | Step 1: regenerate the release's calldata on a fork, verify it (`verify-bootstrap`), and publish the **deploy bundle** (`ecosystem-upgrade-deploy-inputs-<env>`). Its `verify-bundle-handoff` job re-deploys + re-verifies that bundle from the artifact and the image it names, with no contract build, proving it is self-sufficient. |
| `deploy-ecosystem-upgrade`            | Step 2: broadcast the bundle's deployer calls to a real L1, then verify on Etherscan. Takes the step-1 run id.                                                                                                                                                                                                                          |

See [`docs/ecosystem-upgrade-deploy.md`](../../docs/ecosystem-upgrade-deploy.md)
for the local equivalents (`protocol_ops ecosystem rehearse-upgrade` and
`replay-bundle`) and why the bundle — not a re-run — is what
transfers between machines.

## Conventions

- **Calldata workflows** share: `environment`, `protocol_ops_tag`, `l1_rpc_url`
- **`environment`** is a preset the image holds: `l1-contracts/upgrade-envs/permanent-values/<env>.toml`
  (`stage`, `testnet`, `mainnet` or a partner's), passed as `--env <env>`; it gives the bridgehub and
  the L1 chain id. It is a free string, so a new partner preset needs no workflow change.
  Chain workflows take the chain as `chain_id` (`--chain-id`).
- **Integration-test-only** env vars (e.g. `L1_DIAMOND_CUT_DATA`) are NOT workflow inputs
- **v30-only** overrides are marked `[v30 only]` in descriptions and `TODO(v30-removal)` in code
- **Artifact names**: per-chain workflows upload `safe-bundles-{operation}-{chain_id}-{environment}`

## CI tiers

PR CI is split into a per-commit tier and a pre-merge tier (the committed-generated-artifact
checks, skipped while a PR is a draft). That split, and the one-dispatch regen that clears it,
are documented in [docs/ai-review/docs/ci-green.md](../../docs/ai-review/docs/ci-green.md).
