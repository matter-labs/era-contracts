# v0.33.2 — verifier-only upgrade (ZKsync OS stage)

v0.33.2 ships the ZKsync OS verification key from #2544 and nothing else. No facet is cut, the chain
creation parameters stay as they are, and no L2 code changes. The CTM moves from v0.33.0 straight to
v0.33.2. It never took v0.33.1 (#2497), and `createNewVerifierOnlyUpgrade` allows skipping patches.

| VK                                | `recursion_scheduler_level_vk_hash`                                  |
| --------------------------------- | -------------------------------------------------------------------- |
| live today (v0.33.0, all chains)  | `0x29651d5f044e1671ff820f85018ed87b26f57402222eb31dd453206e2379bc9c` |
| v0.33.2 (`zksync-os/latest.json`) | `0xec24ed291193c0f86d53b242e45490f05e2328817d9decb8cc4188b582682bfa` |

## Which ecosystem

This is the atomic-interop stage ecosystem deployed from this branch on 2026-08-27. It is **not** the
older stage ecosystem that `../v0.33.0-atomic-interop/stage.toml` describes (bridgehub `0x236D1c3F…`,
owned by the stage ProtocolUpgradeHandler). Everything below was read from Sepolia:

| what                        | address                                      | notes                                                                               |
| --------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------- |
| Bridgehub                   | `0xb9415d43C7753cCeBaa1ac05c8BabA36159ab13F` |                                                                                     |
| ZKsync OS CTM               | `0x94d8784d719181EA00f58ab4a85333959FFA5a79` | `isZKsyncOS() == true`, on `0x2100000000` (v0.33.0), the only CTM on this bridgehub |
| ChainAssetHandler           | `0x33388639Ba3f30AD47fc6e6769CEe89e53a09991` | holds `pauseMigration` / `unpauseMigration`                                         |
| Governance                  | `0xFF657F253C0FbdE6A7DeCdc958F4153C1179D3aa` | owns the CTM and the ChainAssetHandler; `minDelay() == 0`                           |
| Governance owner            | `0xd2d5391421f98A0086F4143D2EA0337a31Ca89E5` | EOA; also the security council and the owner of every ChainAdmin below              |
| CTM `defaultUpgrade`        | `0x142d4EaBBA644907b6C51b08b19684e40de3dCC4` | byte-identical to this branch's `DefaultUpgradeZKsyncOS`                            |
| verifier for v0.33.0        | `0x23461C3EF806ea8e87e88A6DA584C84f884A3055` | `ZKsyncOSTestnetVerifier`                                                           |
| bridgehub admin / CTM admin | `0xa95BaE85Fd551603f9ddAfD1827aC11fab6971C0` | `ChainAdminOwnable`                                                                 |

Chains, all on v0.33.0 and settling on Sepolia, each behind its own `ChainAdminOwnable`:
2727, 2728, 2729, 27271, 27272, 27273. Chain 2727 has never committed a batch and still carries the
production verifier `0x2aEa8C51…` from the original deployment; the upgrade moves it to the new one
like every other chain.

## What the upgrade does

The script extends `DefaultCTMUpgrade` and keeps its flow: configuration from
`configs/genesis/zksync-os/latest.json`, address discovery from the CTM, `deployVerifiers`, the
`UpgradeStageValidator` / `GovernanceUpgradeTimer` pair, the stage 0/1/2 scaffold, the test calls and the
standard output. Stage 1 differs: it registers the new version with `createNewVerifierOnlyUpgrade`, and
skips the proxy upgrades, `setDefaultUpgrade`, `setChainCreationParams` and `setNewVersionUpgrade`.

| step                    | sender                                 | calls                                                                                                                                       |
| ----------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| deploy (permissionless) | any EOA                                | CREATE2 factory: `ZKsyncOSVerifierPlonk`, `ZKsyncOSTestnetVerifier(plonk)`, `UpgradeStageValidator(ctm, v0.33.2)`, `GovernanceUpgradeTimer` |
| stage 0                 | Governance                             | `ChainAssetHandler.pauseMigration()`, `GovernanceUpgradeTimer.startTimer()`                                                                 |
| stage 1                 | Governance                             | `checkDeadline()`, `checkMigrationsPaused()`, `CTM.createNewVerifierOnlyUpgrade(0x2100000000, type(uint256).max, 0x2100000002, verifier)`   |
| stage 2                 | Governance                             | `checkProtocolUpgradePresence()`, `ChainAssetHandler.unpauseMigration()`, `checkMigrationsUnpaused()`                                       |
| per chain               | the chain's ChainAdmin, from its owner | `ServerNotifier.setUpgradeTimestamp(chainId, ts)`, then `upgradeChainFromVersion(chain, 0x2100000000, cut)`                                 |

The addresses of the new contracts are in `[state_transition]` (`verifier_addr`, `verifier_plonk_addr`) and
`[deployed_addresses]` (`upgrade_stage_validator`, `l1_governance_upgrade_timer`) of the output. The timer's
initial delay is 0, as in the v29.5 VK patch: nothing on L2 changes, so stage 1 may follow stage 0
immediately.

`createNewVerifierOnlyUpgrade` builds the cut itself: no facet cuts, `initAddress` = the stored
`defaultUpgrade`, `initCalldata` = `upgradeVerifierOnly(0x2100000002)`. It also carries the chain
creation params over to the new version. The old version keeps a `type(uint256).max` deadline
(`UpgradeHelperLib.getOldProtocolDeadline`), so nothing forces a chain over before its prover is ready.

Each governance stage is one `Governance` operation: the owner sends `scheduleTransparent(op, 0)` then
`execute(op)`. `[governance_operations]` in the output has both calldatas per stage.

**Per chain, the cut needs every committed batch executed.** `DefaultUpgradeZKsyncOS.upgrade` reverts
with `NotAllBatchesExecuted()` otherwise. At the rehearsal's fork block, only 2727 and 2728 were idle.
Chains 2729, 27271, 27272 and 27273 had batches in flight, so their operators must drain the queue
first. The cut sets no DA: every chain keeps its validator pair and pubdata content (see
`output/stage/chain-upgrades/README.md`).

## Files

- `stage.toml` is the input: bridgehub, CTM, the expected current version, the verifier flavour, the
  timer delay, the CREATE2 salt and the chain list. The script checks it against the live state.
- `output/stage/ecosystem.toml` is the artifact. On top of the standard `DefaultCTMUpgrade` output
  (`[state_transition]`, `[deployed_addresses]`, `[contracts_config]`, `chain_upgrade_diamond_cut`,
  `[governance_calls]`, `[test_upgrade_calls]` with `test_create_chain_zkos`), it carries:
  - `[verification_key]`: the old and new VK hashes;
  - `[deploy_calls]`: the four CREATE2 factory calls and the contract names;
  - `[governance_operations]`: the Governance `scheduleTransparent` / `execute` calldata;
  - `[chain_upgrades.<id>]`: each ChainAdmin's `multicall` calldata.
- `output/stage/chain-upgrades/<id>/` holds the per-chain bundles, made by `protocol_ops chain
set-upgrade-timestamp` and `chain upgrade` as for the v33 testnet chains. Each has
  `01_chain.set-upgrade-timestamp_*.safe.json`, `02_chain.upgrade_*.safe.json` and `manifest.json`;
  see the README there.
- `output/stage/simulator/` holds the transaction-simulator scenarios: `…-stage-1-ecosystem.json`, and
  one `…-stage-2-chain-<id>.json` per chain.
- `generate-stage.sh` regenerates `ecosystem.toml` and the ecosystem scenario.
- `generate-chain-upgrades-stage.sh` regenerates the per-chain bundles and their scenarios, on a fork
  where `apply-ecosystem-upgrade-to-fork.sh` has applied the ecosystem upgrade.
- `deploy-stage.sh` broadcasts the `[deploy_calls]` (idempotent) and appends the hashes to
  `output/stage/transactions.txt`.
- `rehearse-stage.sh` replays the real execution path on a Sepolia fork and asserts the end state.
- `sim-descriptions.toml` holds the scenario's human-readable descriptions.

Script: `deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol`. It is run without
`--broadcast`: the deployments only happen on the local fork, which is where the script checks that the
deployed VK equals `configs/genesis/zksync-os/latest.json`.

## Deployed on Sepolia

The four contracts were deployed on 2026-10-06 with `deploy-stage.sh` and are source-verified on
Etherscan. They are inert until stage 1 names them. Hashes are in `output/stage/transactions.txt`.

| contract                  | address                                      | deploy tx     |
| ------------------------- | -------------------------------------------- | ------------- |
| `ZKsyncOSVerifierPlonk`   | `0xB548D8028a82A635C6E506f7045FE29F331C897c` | `0x04346299…` |
| `ZKsyncOSTestnetVerifier` | `0x5130E7D98b45E50dD059B1Ffc870077be49EBef6` | `0xc14cfab5…` |
| `UpgradeStageValidator`   | `0xd4cf05E557C28eC06952dB961Bd371a254223014` | `0xd8b38c2e…` |
| `GovernanceUpgradeTimer`  | `0xa1FAdE7c8863D9f6ebF59B25b0C693b291ecd9d4` | `0x33aa5c11…` |

On chain, `verificationKeyHash()` of `0x5130E7D9…` is `0xec24ed29…` and `IS_TESTNET_VERIFIER()` is
true. Etherscan verification used upstream forge 1.8 (Etherscan V2) from the default profile, the one
the bytecode was built with. `ZKsyncOSTestnetVerifier` and `GovernanceUpgradeTimer` were matched to
identical bytecode Etherscan had already verified.

## Running it

Build with foundry-zksync v0.1.5, the CI pin. That build reproduces `AllContractsHashes.json` for the
verifier contracts, so the CREATE2 addresses are reproducible.

```bash
cd protocol-ops && cargo build --release && cd ..
cd l1-contracts && forge build
L1_RPC=<sepolia rpc> DEPLOYER_PK_FILE=<file> ./upgrade-envs/v0.33.2-verifier/deploy-stage.sh
L1_RPC=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/generate-stage.sh 2026-10-05
L1_FORK_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/generate-chain-upgrades-stage.sh 2026-10-05
L1_FORK_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/rehearse-stage.sh
```

## Executing it

1. Deploy: done (see "Deployed on Sepolia"). `deploy-stage.sh` skips contracts that already exist.
2. As the Governance owner, send `stageN_schedule_calldata` then `stageN_execute_calldata` to the
   Governance for N = 0, 1, 2. They can go back to back, since `minDelay` and the timer delay are 0.
3. Per chain, once the v0.33.2 prover is live and the chain has no unexecuted batches, the
   ChainAdmin's owner executes `output/stage/chain-upgrades/<id>/01_*` (`setUpgradeTimestamp`), then
   `02_*` (the cut).

## Validation

| check                                                                                | result                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| creation bytecode of the verifier contracts vs `AllContractsHashes.json`             | identical                                                                                                                                                                                                                                                                                     |
| deployed VK vs `zksync-os/latest.json` (asserted by the script)                      | `0xec24ed29…`, also on the live `0x5130E7D9…`                                                                                                                                                                                                                                                 |
| `rehearse-stage.sh` on a Sepolia fork (block 11854801), against the live deployments | `REHEARSAL PASSED`: CTM on v0.33.2 with the new verifier and stored cut, creation params unchanged, migrations unpaused; the committed chain bundles upgrade every chain idle at that block (2727, 2728, 27271), the others refuse with `NotAllBatchesExecuted`; chain 556 created on v0.33.2 |
| per-chain cut bundles vs `[chain_upgrades.<id>].chain_admin_calldata`                | byte-identical, all six                                                                                                                                                                                                                                                                       |
| transaction-simulator `yarn simulate --ci` on all seven scenarios, one fork          | `✅ All simulations succeed!` for each: the ecosystem file, then all six chains taking the timestamp and the cut                                                                                                                                                                              |

## Transaction-simulator notes

- The scenario's `stage0/1/2` entries are sent by the Governance contract, impersonated, which is the
  shape the simulator's era-contracts copy-paste check derives from `ecosystem.toml`. That check
  currently hardcodes stage's owner as the old ProtocolUpgradeHandler `0x8f086275…`, so registering
  this file in `era-contracts-provenance.json` also needs this ecosystem's Governance added there.
- The CREATE2 deployments are not in the scenario: they are live on Sepolia, so the fork already has
  them. `generate-stage.sh` refuses to emit the scenario while any of them is missing.
- Like the v33 testnet artifact, the ecosystem scenario carries an `ack_test_upgrade_chain_zkos` marker
  instead of a generated test upgrade, since the per-chain scenarios are the real coverage. The chain
  scenarios use `emulateAllBatchesExecutedFor`. Both need the transaction-simulator branch
  `sb/v33-atomic-interop-testnet`, the same one the v33 testnet scenarios need.
