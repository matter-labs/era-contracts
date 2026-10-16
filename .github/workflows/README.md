# Calldata Generation Workflows

Each `generate-*.yaml` workflow invokes a `protocol_ops` subcommand inside a released
`ghcr.io/matter-labs/protocol-ops` image, via `protocol-ops.sh --tag <docker-tag>` (the wrapper
forwards the rest of the args to `protocol_ops` unless the first post-flag word is `forge`/`cast`).
Nothing is compiled per run: the image is what gets released and tested.

## Release flow

1. Merge the PRs that change the upgrade's scripts and inputs (`l1-contracts/upgrade-envs/<upgrade>/`,
   `AllContractsHashes.json`, the chain states).
2. Run zksync-os-integration-tests against that commit.
3. Release the image: dispatch `build-docker` on that commit with `tested_with_integration_tests=true`
   and `integration_tests_run_url=<that run>`; it refuses to push without them. Before pushing, it runs
   the anvil-interop upgrade test (`run-upgrade-test.ts`: the previous release's chain states, upgraded
   with this image's `protocol_ops`) inside the image. The run summary gives the tag and digest.
4. Pass that tag as `protocol_ops_tag` to `generate-ecosystem-upgrade-calldata` and the chain
   workflows; `deploy-ecosystem-upgrade` runs the image its bundle names.

`protocol_ops_tag` is an image tag or `sha256:<digest>`. Images without the
`org.opencontainers.image.revision` label `build-docker` sets (such as those `build-and-push-docker`
pushes for zksync-os-integration-tests) are refused. The ecosystem workflow checks out the commit the
image was built from, so its configs are the image's: a change to `upgrade-envs/<upgrade>/<env>.toml`
(salts, owners) needs a new image. Its deploy bundle records the image digest, which
`verify-bundle-handoff` and `deploy-ecosystem-upgrade` run. The chain workflows run on the dispatched
branch, whose `upgrade-envs/` is mounted into the image.

### For partners

Share the digest from the run summary. A partner (ADI) runs chain operations with `docker run` and no
checkout, and signs and broadcasts with its own keys:
[docs/protocol-ops-for-partners.md](../../docs/protocol-ops-for-partners.md). Our deployer keys serve
only `stage`, `testnet` and `mainnet`: `execute-deployer-safe-bundles` offers no other, the
`deploy-ecosystem-upgrade` broadcast refuses any other, and generate takes a blank `deployer_address`
(our deployer) for no other.

## Mapping

| Workflow                                        | Entry point                                |
| ----------------------------------------------- | ------------------------------------------ |
| `generate-chain-init-calldata`                  | `protocol-ops chain init`                  |
| `generate-chain-upgrade-calldata`               | `protocol-ops chain upgrade`               |
| `generate-chain-set-upgrade-timestamp-calldata` | `protocol-ops chain set-upgrade-timestamp` |
| `generate-chain-add-validator-calldata`         | `protocol-ops chain add-validator`         |
| `generate-chain-remove-validator-calldata`      | `protocol-ops chain remove-validator`      |

## Execute workflows

| Workflow                        | Purpose                                                                                                                                                                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `execute-deployer-safe-bundles` | Apply Safe bundles whose `target` is the ecosystem deployer EOA (e.g. the chain-init workflow's). Our ecosystems only (`stage`, `testnet`, `mainnet`): signs with the deployer secret of the preset's L1, `DEPLOYER_PRIVATE_KEY_SEPOLIA` or `_MAINNET`, and refuses bundles that target another EOA. |

## Ecosystem-upgrade workflows

| Workflow                              | Purpose                                                                                                                                                                                                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `generate-ecosystem-upgrade-calldata` | Step 1: regenerate the release's calldata on a fork, PUVT it, and publish the **deploy bundle** (`ecosystem-upgrade-deploy-inputs-<env>`). Its `verify-bundle-handoff` job re-deploys + re-verifies that bundle with no contract build, proving it is self-sufficient. |
| `deploy-ecosystem-upgrade`            | Step 2: broadcast the bundle's deployer calls to a real L1, then verify on Etherscan. Takes the step-1 run id.                                                                                                                                                         |

See [`docs/ecosystem-upgrade-deploy.md`](../../docs/ecosystem-upgrade-deploy.md)
for the local equivalents (`protocol_ops ecosystem rehearse-upgrade` and
`replay-bundle`) and why the bundle — not a re-run — is what
transfers between machines.

## Conventions

- **All workflows** share: `environment`, `protocol_ops_tag`, `l1_rpc_url`
- **`environment`** is a preset: `l1-contracts/upgrade-envs/permanent-values/<env>.toml` (`stage`,
  `testnet`, `mainnet`, `adi`), passed as `--env <env>`; it gives the bridgehub and the L1 chain id.
  Chain workflows take the chain as `chain_id` (`--chain-id`). What uses our deployer keys takes only
  ours (see [For partners](#for-partners)).
- **Integration-test-only** env vars (e.g. `L1_DIAMOND_CUT_DATA`) are NOT workflow inputs
- **v30-only** overrides are marked `[v30 only]` in descriptions and `TODO(v30-removal)` in code
- **Artifact names**: per-chain workflows upload `safe-bundles-{operation}-{chain_id}-{environment}`

## CI tiers

PR CI is split into a per-commit tier and a pre-merge tier (the committed-generated-artifact
checks, skipped while a PR is a draft). That split, and the one-dispatch regen that clears it,
are documented in [docs/ai-review/docs/ci-green.md](../../docs/ai-review/docs/ci-green.md).
