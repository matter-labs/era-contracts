# v0.33.2 — verifier-only upgrade (ZKsync OS)

v0.33.2 ships the ZKsync OS verification key from #2544 and nothing else. No facet is cut, the chain
creation parameters stay as they are, and no L2 code changes. A CTM moves from v0.33.0 straight to v0.33.2.
It never took v0.33.1 (#2497), and `createNewVerifierOnlyUpgrade` allows skipping patches.

| VK                                | `recursion_scheduler_level_vk_hash`                                  |
| --------------------------------- | -------------------------------------------------------------------- |
| v0.33.0 (live before the upgrade) | `0x29651d5f044e1671ff820f85018ed87b26f57402222eb31dd453206e2379bc9c` |
| v0.33.2 (`zksync-os/latest.json`) | `0xec24ed291193c0f86d53b242e45490f05e2328817d9decb8cc4188b582682bfa` |

| env       | ecosystem                                                | governance                                       | details                                              |
| --------- | -------------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------- |
| `stage3`  | atomic-interop stage ("stage3"), bridgehub `0xb9415d43…` | `Governance` `0xFF657F25…` (EOA owner)           | [output/stage3/README.md](output/stage3/README.md)   |
| `testnet` | public ZKsync OS testnet, bridgehub `0xc4FD2580…`        | ProtocolUpgradeHandler `0x803e5E7a…` (emergency) | [output/testnet/README.md](output/testnet/README.md) |

The env name is the basename of `../permanent-values/<env>.toml` and `<env>.toml` here, as everywhere in the
generate / deploy pipeline. `stage3` is not `stage`: `permanent-values/stage.toml` is the older stage ecosystem.

## What the upgrade does

The script, `deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol`, extends
`DefaultCTMUpgrade` and keeps its flow: configuration from `configs/genesis/zksync-os/latest.json`, address
discovery from the CTM, `deployVerifiers`, the `UpgradeStageValidator` / `GovernanceUpgradeTimer` pair, the
stage 0/1/2 scaffold, the test calls and the standard output. Stage 1 differs: it registers the new version
with `createNewVerifierOnlyUpgrade`, and skips the proxy upgrades, `setDefaultUpgrade`,
`setChainCreationParams` and `setNewVersionUpgrade`.

| step                    | sender                                 | calls                                                                                                                                                                                                             |
| ----------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| deploy (permissionless) | any EOA                                | CREATE2 factory: `ZKsyncOSVerifierPlonk`, `ZKsyncOSTestnetVerifier(plonk)`, `UpgradeStageValidator(ctm, v0.33.2)`, `GovernanceUpgradeTimer`                                                                       |
| stage 0                 | the CTM owner                          | `ChainAssetHandler.pauseMigration()`, `GovernanceUpgradeTimer.startTimer()`                                                                                                                                       |
| stage 1                 | the CTM owner                          | ProtocolUpgradeHandler only: `ChainAssetHandler.pauseMigration()`; then `checkDeadline()`, `checkMigrationsPaused()`, `CTM.createNewVerifierOnlyUpgrade(0x2100000000, type(uint256).max, 0x2100000002, verifier)` |
| stage 2                 | the CTM owner                          | `checkProtocolUpgradePresence()`, `ChainAssetHandler.unpauseMigration()`, `checkMigrationsUnpaused()`                                                                                                             |
| per chain               | the chain's ChainAdmin, from its owner | `ServerNotifier.setUpgradeTimestamp(chainId, 1)`, then `upgradeChainFromVersion(chain, 0x2100000000, cut)`                                                                                                        |

How the CTM owner sends the stages depends on the ecosystem:

- a `Governance` with an EOA owner: one operation per stage, `scheduleTransparent(op, 0)` then `execute(op)`
  (`[governance_operations]` in the output);
- a ProtocolUpgradeHandler: one emergency proposal per stage through the Emergency Upgrade Board, each the
  board owner's `approveHash` on each member Safe then `executeEmergencyUpgrade`. `executeEmergencyUpgrade`
  unpauses migrations before it runs a proposal's calls, which undoes stage 0's pause, so stage 1 pauses them
  again first (as the release's stage 1 does); a `Governance` runs the calls as given and needs no repeat.

Either way the pipeline writes the transactions to `output/<env>/execution.json` and renders them as
`output/<env>/EXECUTE.md`: for a ProtocolUpgradeHandler through `EmergencyStageUpgradeCalldata.emergencyUpgradeEachStage`, for a
`Governance` from `[governance_operations]` itself.

`createNewVerifierOnlyUpgrade` builds the cut itself: no facet cuts, `initAddress` = the stored
`defaultUpgrade`, `initCalldata` = `upgradeVerifierOnly(0x2100000002)`. It also carries the chain creation
params over to the new version. The old version keeps a `type(uint256).max` deadline
(`UpgradeHelperLib.getOldProtocolDeadline`), so nothing forces a chain over before its prover is ready. The
timer's initial delay is 0, as in the v29.5 VK patch: nothing on L2 changes.

**Per chain, the cut needs every committed batch executed.** `DefaultUpgradeZKsyncOS.upgrade` reverts with
`NotAllBatchesExecuted()` otherwise, so a chain's operator drains its queue first. The cut sets no DA: every
chain keeps its validator pair and pubdata content.

## Files

This directory holds data only. The pipeline runs it as a verifier-only upgrade, so another VK-only upgrade
is a copy of `upgrade.toml` and the `<env>.toml` inputs in a new directory, with no script of its own.

- `upgrade.toml`: `prepare = "prepare-all"` with `verifier_only = true`. The generate / deploy pipeline
  (`protocol-ops/src/common/upgrade_descriptor.rs`) then runs `protocol_ops ecosystem upgrade-prepare-all
--verifier-only --upgrade v0.33.2-verifier --env <env>`, writes the execution transactions, and checks the
  result with its built-in verifier-only checks (`protocol-ops/src/commands/ecosystem/verifier_only_check.rs`):
  - on the generation fork, after the deploy bundle: the deployments and their wiring, the execution
    transactions carry exactly stages 0-2 of `[governance_calls]`, the stages from the CTM owner, the committed
    per-chain bundles (a chain with batches in flight must refuse the cut with `NotAllBatchesExecuted`, every
    other chain must upgrade), a chain created after the upgrade, and the resulting CTM state;
  - against Sepolia after the deploy workflow's broadcast: the deployments and their wiring, read-only.
- `<env>.toml` is the input: bridgehub, CTM, the expected current version, the governance kind, the verifier
  flavour, the timer delay, the CREATE2 salt and the chain list. The script checks it against the live state.
- `output/<env>/` holds everything for one environment. A run rewrites what it produces and leaves the rest alone:
  - written by the generate workflow (`rehearse-upgrade`):
    - `ecosystem.toml`, the artifact. On top of the standard `DefaultCTMUpgrade` output (`[state_transition]`,
      `[deployed_addresses]`, `[contracts_config]`, `chain_upgrade_diamond_cut`, `[governance_calls]`,
      `[test_upgrade_calls]` with `test_create_chain_zkos`), it carries `[verification_key]` (the old and new
      VK hashes), `[deploy_calls]` (the four CREATE2 factory calls), `[governance_operations]`
      (Governance-owned ecosystems: the `scheduleTransparent` / `execute` calldata) and
      `[chain_upgrades.<id>]` (each ChainAdmin's `multicall` calldata);
    - `execution.json` and `EXECUTE.md`: the governance transactions and their MetaMask runbook;
    - `extra-verification-logs.txt`: the Etherscan commands;
    - `simulator/…-<env>-1-ecosystem.json`: the ecosystem transaction-simulator scenario;
    - not committed: `deploy-bundle/` (the deployer's calls, what the deploy workflow broadcasts), `prepare/`,
      `fork-rehearsal/`;
  - written by the per-chain workflow (`generate-chain-upgrade-calldata.yaml`), once the ecosystem is upgraded:
    - `chain-upgrades/<id>/`: the per-chain bundles from `protocol_ops chain set-upgrade-timestamp` and
      `chain upgrade`: `01_chain.set-upgrade-timestamp_*.safe.json`, `02_chain.upgrade_*.safe.json` and
      `manifest.json`;
    - `simulator/…-<env>-2-chain-<id>.json`: one scenario per chain;
  - by hand: `README.md` (the env's addresses, status and validation) and `transactions.txt` (the Sepolia
    deployment hashes, from the deploy workflow's result).

Nothing here broadcasts the upgrade script: the deployments only happen on forks until someone sends the
deploy bundle. The script checks there that the deployed VK equals `configs/genesis/zksync-os/latest.json`.

## Running it

In CI, on a branch of this repository with this directory:

```bash
# 1. the ecosystem calldata, the deploy bundle, EXECUTE.md and the ecosystem scenario
gh workflow run generate-ecosystem-upgrade-calldata.yaml --ref <branch> -f upgrade=v0.33.2-verifier \
  -f environment=<env> -f deployer_address=<the EOA that will deploy> [-f fork_block=<n>] [-f commit_outputs=true]
# 2. the deployments
gh workflow run deploy-ecosystem-upgrade.yaml --ref <branch> -f environment=<env> -f generate_run_id=<run id>
# 3. governance sends the EXECUTE.md transactions
# 4. per chain, once the CTM is on the new version
gh workflow run generate-chain-upgrade-calldata.yaml --ref <branch> -f environment=<env> -f chain_id=<id> \
  -f protocol_ops_tag=<tag> -f upgrade=v0.33.2-verifier -f upgrade_timestamp=1 \
  [-f commit_outputs=true]
```

The deploy run broadcasts the deploy bundle from `DEPLOYER_PRIVATE_KEY_SEPOLIA`, which must be that
`deployer_address`, checks the deployments on Sepolia and verifies the contracts on Etherscan. The CREATE2
addresses do not depend on the deployer. Once the contracts are live, generate with `fork_block` before their
deployment: the prepare deploys nothing at the tip, and the pipeline refuses an empty deploy bundle.

Locally, the same commands, with foundry-zksync v0.1.5 (the CI pin) first on PATH and upstream anvil >= 1.8.3
after it. Sepolia has run Glamsterdam since 2026-10-06, and an older anvil forks it under rules that
under-price code deposit:

```bash
cd protocol-ops && cargo build --release && cd ..
protocol-ops/target/release/protocol_ops ecosystem rehearse-upgrade --upgrade v0.33.2-verifier --env <env> \
  --fork-url <sepolia rpc> --deployer-address <eoa> [--fork-block <n>]
protocol-ops/target/release/protocol_ops ecosystem replay-bundle \
  --bundle l1-contracts/upgrade-envs/v0.33.2-verifier/output/<env>/deploy-bundle --rpc <sepolia rpc> --verify-only
```

## Transaction-simulator notes

- The scenarios' `stage0/1/2` entries are sent by the CTM owner, impersonated, which is the shape the
  simulator's era-contracts copy-paste check derives from `ecosystem.toml`.
- The CREATE2 deployments are not in the scenarios: they are live on Sepolia, so the fork already has them.
- The ecosystem scenario carries no generated test upgrade; its `test_upgrade_chain_zkos` entry is an inert
  `alreadyExecuted` placeholder pointing at the per-chain scenarios, which use `emulateAllBatchesExecutedFor`.
