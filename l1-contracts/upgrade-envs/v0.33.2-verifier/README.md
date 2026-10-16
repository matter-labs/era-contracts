# v0.33.2 — verifier-only upgrade (ZKsync OS)

v0.33.2 ships the ZKsync OS verification key from #2544 and nothing else. No facet is cut, the chain
creation parameters stay as they are, and no L2 code changes. A CTM moves from v0.33.0 straight to v0.33.2.
It never took v0.33.1 (#2497), and `createNewVerifierOnlyUpgrade` allows skipping patches.

| VK                                | `recursion_scheduler_level_vk_hash`                                  |
| --------------------------------- | -------------------------------------------------------------------- |
| v0.33.0 (live before the upgrade) | `0x29651d5f044e1671ff820f85018ed87b26f57402222eb31dd453206e2379bc9c` |
| v0.33.2 (`zksync-os/latest.json`) | `0xec24ed291193c0f86d53b242e45490f05e2328817d9decb8cc4188b582682bfa` |

| env       | ecosystem                                                | governance                                       | details                                |
| --------- | -------------------------------------------------------- | ------------------------------------------------ | -------------------------------------- |
| `stage3`  | atomic-interop stage ("stage3"), bridgehub `0xb9415d43…` | `Governance` `0xFF657F25…` (EOA owner)           | [stage3/README.md](stage3/README.md)   |
| `testnet` | public ZKsync OS testnet, bridgehub `0xc4FD2580…`        | ProtocolUpgradeHandler `0x803e5E7a…` (emergency) | [testnet/README.md](testnet/README.md) |

The env name is the basename of `../permanent-values/<env>.toml` and `<env>.toml` here, as everywhere in the
generate / deploy pipeline. `stage3` is not `stage`: `permanent-values/stage.toml` is the older stage ecosystem.

## What the upgrade does

The script, `deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol`, extends
`DefaultCTMUpgrade` and keeps its flow: configuration from `configs/genesis/zksync-os/latest.json`, address
discovery from the CTM, `deployVerifiers`, the `UpgradeStageValidator` / `GovernanceUpgradeTimer` pair, the
stage 0/1/2 scaffold, the test calls and the standard output. Stage 1 differs: it registers the new version
with `createNewVerifierOnlyUpgrade`, and skips the proxy upgrades, `setDefaultUpgrade`,
`setChainCreationParams` and `setNewVersionUpgrade`.

| step                    | sender                                 | calls                                                                                                                                       |
| ----------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| deploy (permissionless) | any EOA                                | CREATE2 factory: `ZKsyncOSVerifierPlonk`, `ZKsyncOSTestnetVerifier(plonk)`, `UpgradeStageValidator(ctm, v0.33.2)`, `GovernanceUpgradeTimer` |
| stage 0                 | the CTM owner                          | `ChainAssetHandler.pauseMigration()`, `GovernanceUpgradeTimer.startTimer()`                                                                 |
| stage 1                 | the CTM owner                          | `checkDeadline()`, `checkMigrationsPaused()`, `CTM.createNewVerifierOnlyUpgrade(0x2100000000, type(uint256).max, 0x2100000002, verifier)`   |
| stage 2                 | the CTM owner                          | `checkProtocolUpgradePresence()`, `ChainAssetHandler.unpauseMigration()`, `checkMigrationsUnpaused()`                                       |
| per chain               | the chain's ChainAdmin, from its owner | `ServerNotifier.setUpgradeTimestamp(chainId, 1)`, then `upgradeChainFromVersion(chain, 0x2100000000, cut)`                                  |

How the CTM owner sends the stages depends on the ecosystem:

- a `Governance` with an EOA owner: one operation per stage, `scheduleTransparent(op, 0)` then `execute(op)`
  (`[governance_operations]` in the output);
- a ProtocolUpgradeHandler: stages 0-2 as one emergency proposal through the Emergency Upgrade Board, the
  board owner's `approveHash` on each member Safe then `executeEmergencyUpgrade`. One proposal is equivalent
  to three because the timer delay is 0.

Either way `ZKsyncOSVerifierOnlyExecution.s.sol` writes the transactions to `output/<env>/execution.json` (for a
ProtocolUpgradeHandler through `EmergencyStageUpgradeCalldata.s.sol`), and the pipeline renders them as
`output/<env>/EXECUTE.md`.

`createNewVerifierOnlyUpgrade` builds the cut itself: no facet cuts, `initAddress` = the stored
`defaultUpgrade`, `initCalldata` = `upgradeVerifierOnly(0x2100000002)`. It also carries the chain creation
params over to the new version. The old version keeps a `type(uint256).max` deadline
(`UpgradeHelperLib.getOldProtocolDeadline`), so nothing forces a chain over before its prover is ready. The
timer's initial delay is 0, as in the v29.5 VK patch: nothing on L2 changes.

**Per chain, the cut needs every committed batch executed.** `DefaultUpgradeZKsyncOS.upgrade` reverts with
`NotAllBatchesExecuted()` otherwise, so a chain's operator drains its queue first. The cut sets no DA: every
chain keeps its validator pair and pubdata content.

## Files

- `upgrade.toml` tells the generate / deploy pipeline (`protocol-ops/src/common/upgrade_descriptor.rs`) how to
  run this upgrade: the prepare script, the `[execution]` script, and the checks (`rehearse.sh` on a fork,
  `check-deployment.sh` against the real chain).
- `<env>.toml` is the input: bridgehub, CTM, the expected current version, the governance kind, the verifier
  flavour, the timer delay, the CREATE2 salt and the chain list. The script checks it against the live state.
- `output/<env>/` is what the pipeline writes; `rehearse-upgrade` clears it on every run, all but
  `transactions.txt`:
  - `ecosystem.toml`, the artifact. On top of the standard `DefaultCTMUpgrade` output (`[state_transition]`,
    `[deployed_addresses]`, `[contracts_config]`, `chain_upgrade_diamond_cut`, `[governance_calls]`,
    `[test_upgrade_calls]` with `test_create_chain_zkos`), it carries `[verification_key]` (the old and new VK
    hashes), `[deploy_calls]` (the four CREATE2 factory calls), `[governance_operations]` (Governance-owned
    ecosystems: the `scheduleTransparent` / `execute` calldata) and `[chain_upgrades.<id>]` (each ChainAdmin's
    `multicall` calldata);
  - `execution.json` and `EXECUTE.md`: the governance transactions and their MetaMask runbook;
  - `transactions.txt`: the Sepolia deployment hashes;
  - not committed: `deploy-bundle/` (the deployer's calls, what the deploy workflow broadcasts), `prepare/`,
    `fork-rehearsal/`.
- `<env>/` holds what this directory's scripts add, which the pipeline does not regenerate:
  - `README.md`: the env's addresses, status and validation;
  - `chain-upgrades/<id>/`: the per-chain bundles from `protocol_ops chain set-upgrade-timestamp` and
    `chain upgrade`, as for the v33 testnet chains: `01_chain.set-upgrade-timestamp_*.safe.json`,
    `02_chain.upgrade_*.safe.json`, `manifest.json` and, for testnet, the chain's `EXECUTE.md`;
  - `simulator/`: the transaction-simulator scenarios, `…-<env>-1-ecosystem.json` and one
    `…-<env>-2-chain-<id>.json` per chain.
- `sim-descriptions-<env>.toml`: the scenarios' human-readable descriptions.

Scripts, each taking the env:

- `generate.sh <env> [date]` runs `protocol_ops ecosystem rehearse-upgrade --upgrade v0.33.2-verifier`, the
  command the generate workflow runs, then writes the ecosystem scenario. Once the contracts are live, set
  `FORK_BLOCK` to a block before their deployment: the prepare deploys nothing at the tip, and the pipeline
  refuses an empty deploy bundle.
- `deploy.sh <env>` broadcasts the `[deploy_calls]` (idempotent) and records the hashes. The deploy workflow,
  or `protocol_ops ecosystem replay-bundle --bundle output/<env>/deploy-bundle --rpc <l1> --key <key>`, sends
  the same calls from the deploy bundle.
- `generate-chain-upgrades.sh <env> [date]` regenerates the per-chain bundles and their scenarios on a fork
  where `apply-ecosystem-upgrade-to-fork.sh <env>` has applied the ecosystem upgrade.
- `rehearse.sh <env>` replays the real execution path on a Sepolia fork and asserts the end state.
- `check-deployment.sh <env>` checks the live deployments, read-only.

The upgrade script is never broadcast by these scripts: the deployments only happen on forks until someone
sends the deploy bundle. The script checks there that the deployed VK equals `configs/genesis/zksync-os/latest.json`.

## Running it

In CI, on a branch with this directory:

```bash
gh workflow run generate-ecosystem-upgrade-calldata.yaml --ref <branch> -f upgrade=v0.33.2-verifier \
  -f environment=<env> -f deployer_address=<the EOA that will deploy> [-f fork_block=<n>]
gh workflow run deploy-ecosystem-upgrade.yaml --ref <branch> -f environment=<env> -f generate_run_id=<run id>
```

The deploy run broadcasts the deploy bundle from `DEPLOYER_PRIVATE_KEY_SEPOLIA`, which must be that
`deployer_address`, runs `check-deployment.sh` against Sepolia and verifies the contracts on Etherscan. The
CREATE2 addresses do not depend on the deployer.

Locally, build with foundry-zksync v0.1.5, the CI pin. That build reproduces `AllContractsHashes.json` for the
verifier contracts, so the CREATE2 addresses are reproducible.

```bash
cd protocol-ops && cargo build --release && cd ..
cd l1-contracts && forge build
L1_RPC=<sepolia rpc> [FORK_BLOCK=<n>] ./upgrade-envs/v0.33.2-verifier/generate.sh <env> <date>
L1_RPC=<sepolia rpc> DEPLOYER_PK_FILE=<file> ./upgrade-envs/v0.33.2-verifier/deploy.sh <env>
L1_FORK_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/generate-chain-upgrades.sh <env> <date>
L1_FORK_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/rehearse.sh <env>
L1_RPC_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/check-deployment.sh <env>
```

Sepolia has run Glamsterdam since 2026-10-06. `generate.sh` and `rehearse.sh` need upstream anvil >= 1.8.3 on
PATH after foundry-zksync, so their forks run Sepolia's rules; `generate-chain-upgrades.sh` needs upstream forge

> = 1.8.3 first on PATH, and simulates the protocol-ops broadcasts under the Amsterdam rules
> (`FOUNDRY_HARDFORK=amsterdam`, the script's default). Otherwise code deposit is under-priced and the fork or
> the real chain rejects the transaction.

## Transaction-simulator notes

- The scenarios' `stage0/1/2` entries are sent by the CTM owner, impersonated, which is the shape the
  simulator's era-contracts copy-paste check derives from `ecosystem.toml`.
- The CREATE2 deployments are not in the scenarios: they are live on Sepolia, so the fork already has them.
- The ecosystem scenario carries no generated test upgrade; its `test_upgrade_chain_zkos` entry is an inert
  `alreadyExecuted` placeholder pointing at the per-chain scenarios, which use `emulateAllBatchesExecutedFor`.
