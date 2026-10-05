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

| step                    | sender                                 | call                                                                                                                    |
| ----------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| deploy (permissionless) | any EOA                                | CREATE2 factory: `ZKsyncOSVerifierPlonk` → `0xA24d08A1…4874`, then `ZKsyncOSTestnetVerifier(plonk)` → `0x6951368f…3A9C` |
| stage 0                 | Governance                             | `ChainAssetHandler.pauseMigration()`                                                                                    |
| stage 1                 | Governance                             | `CTM.createNewVerifierOnlyUpgrade(0x2100000000, type(uint256).max, 0x2100000002, 0x6951368f…3A9C)`                      |
| stage 2                 | Governance                             | `ChainAssetHandler.unpauseMigration()`                                                                                  |
| per chain               | the chain's ChainAdmin, from its owner | `ServerNotifier.setUpgradeTimestamp(chainId, ts)`, then `upgradeChainFromVersion(chain, 0x2100000000, cut)`             |

`createNewVerifierOnlyUpgrade` builds the cut itself: no facet cuts, `initAddress` = the stored
`defaultUpgrade`, `initCalldata` = `upgradeVerifierOnly(0x2100000002)`. It also carries the chain
creation params over to the new version. The old version keeps a `type(uint256).max` deadline, as the
v29.3 stage VK patch did, so nothing forces a chain over before its prover is ready.

Each governance stage is one `Governance` operation: the owner sends `scheduleTransparent(op, 0)` then
`execute(op)`. `[governance_operations]` in the output has both calldatas per stage.

**Per chain, the cut needs every committed batch executed.** `DefaultUpgradeZKsyncOS.upgrade` reverts
with `NotAllBatchesExecuted()` otherwise. At the rehearsal's fork block, only 2727 and 2728 were idle.
Chains 2729, 27271, 27272 and 27273 had batches in flight, so their operators must drain the queue
first.

## Files

- `stage.toml` is the input: bridgehub, CTM, the expected current version, the verifier flavour, the
  CREATE2 salt and the chain list. The script checks all of it against the live state before emitting
  anything.
- `output/stage/ecosystem.toml` is the artifact:
  - `[contracts_config]` has the addresses, versions, old and new VK, and the cut the CTM will store.
  - `[deploy_calls]` holds the two CREATE2 factory calls.
  - `[governance_calls]` holds stages 0/1/2 as `Call[]`.
  - `[governance_operations]` holds the Governance `scheduleTransparent` / `execute` calldata.
  - `[chain_upgrades.<id>]` holds each ChainAdmin's `multicall` calldata.
  - `[test_upgrade_calls]` holds the simulator's smoke tests.
- `output/stage/simulator/2026-10-05-v0.33.2-verifier-stage.json` is the transaction-simulator
  scenario.
- `generate-stage.sh` regenerates both.
- `rehearse-stage.sh` replays the real execution path on a Sepolia fork and asserts the end state.
- `sim-descriptions.toml` holds the scenario's human-readable descriptions.

Script: `deploy-scripts/upgrade/verifier-only/ZKsyncOSVerifierOnlyUpgrade.s.sol`. It never
broadcasts. It deploys the verifiers on the local fork only, to check that the deployed VK equals
`configs/genesis/zksync-os/latest.json`.

## Running it

Build with foundry-zksync v0.1.5, the CI pin. That build reproduces `AllContractsHashes.json` for
`ZKsyncOSVerifierPlonk`, `ZKsyncOSTestnetVerifier` and `ZKsyncOSVerifier`, so the CREATE2 addresses
above are reproducible.

```bash
cd protocol-ops && cargo build --release && cd ..
cd l1-contracts && forge build
L1_RPC=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/generate-stage.sh 2026-10-05
L1_FORK_URL=<sepolia rpc> ./upgrade-envs/v0.33.2-verifier/rehearse-stage.sh
```

## Executing it

1. Send the two `[deploy_calls]` to the CREATE2 factory from any funded EOA. Check that
   `verificationKeyHash()` on `0x6951368f…3A9C` is `0xec24ed29…`.
2. As the Governance owner, send `stageN_schedule_calldata` then `stageN_execute_calldata` to the
   Governance for N = 0, 1, 2. They can go back to back, since `minDelay` is 0.
3. Per chain, once the v0.33.2 prover is live and the chain has no unexecuted batches, the
   ChainAdmin's owner:
   - sends `multicall([ServerNotifier.setUpgradeTimestamp(chainId, ts)], true)` to the ChainAdmin
     (ServerNotifier `0x2A20E03d1E15556fDce96dA891FF454D67172d6E`);
   - then sends `[chain_upgrades.<id>].chain_admin_calldata` to it.

## Validation

| check                                                                          | result                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| creation bytecode of the three verifier contracts vs `AllContractsHashes.json` | identical                                                                                                                                                                                                                   |
| deployed VK vs `zksync-os/latest.json` (asserted by the script)                | `0xec24ed29…`                                                                                                                                                                                                               |
| `rehearse-stage.sh` on a Sepolia fork (block 11850015)                         | `REHEARSAL PASSED`: CTM on v0.33.2 with the new verifier and stored cut, creation params unchanged, migrations unpaused, 2727 / 2728 upgraded, the others refuse with `NotAllBatchesExecuted`, chain 556 created on v0.33.2 |
| transaction-simulator `yarn simulate` on the scenario                          | `✅ All simulations succeed!` (7 txs), chain 556 created on v0.33.2, chain 27271 upgraded to v0.33.2                                                                                                                        |

## Transaction-simulator notes

- The scenario's `stage0/1/2` entries are sent by the Governance contract, impersonated, which is the
  shape the simulator's era-contracts copy-paste check derives from `ecosystem.toml`. That check
  currently hardcodes stage's owner as the old ProtocolUpgradeHandler `0x8f086275…`, so registering
  this file in `era-contracts-provenance.json` also needs this ecosystem's Governance added there.
- The two `deploy_verifier` entries are part of the scenario because nothing is deployed yet. Once
  they are broadcast, mark them `alreadyExecuted: true`. Replaying a CREATE2 deployment reverts.
- `test_upgrade_chain_zkos` carries `emulateAllBatchesExecuted`, for the reason above.
