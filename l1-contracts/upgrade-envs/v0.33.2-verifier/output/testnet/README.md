# v0.33.2 — testnet

The public ZKsync OS testnet on Sepolia (`upgrade-envs/permanent-values/testnet.toml`). Everything below was
read from Sepolia on 2026-10-16.

| what                        | address                                      | notes                                                                               |
| --------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------- |
| Bridgehub                   | `0xc4FD2580C3487bba18D63f50301020132342fdbD` |                                                                                     |
| ZKsync OS CTM               | `0x54D55e74De9c6003E7a68a1fE70E633f05761eb5` | `isZKsyncOS() == true`, on `0x2100000000` (v0.33.0); the one this upgrade touches   |
| EraVM CTM                   | `0x3Cc81628a14C824057a97C1B4Ab17758E5D18864` | on v0.31.0 with its own verifier; not touched                                       |
| ChainAssetHandler           | `0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C` | holds `pauseMigration` / `unpauseMigration`                                         |
| ProtocolUpgradeHandler      | `0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D` | owns the CTMs and the ChainAssetHandler                                             |
| Emergency Upgrade Board     | `0x639B577E6b614971da0B7d50AaA4Bc064c13B872` | 5 Guardians + 6 Security Council + the ZK Foundation Safe approve, all 1-of-1 Safes |
| board / Safes owner         | `0xD64e136566a9E04eb05B30184fF577F52682D182` | EOA; sends all 13 emergency transactions                                            |
| CTM `defaultUpgrade`        | `0xB0747C54B9E8a32cF150e8851bDc259dd26c5990` | the generic `DefaultUpgradeZKsyncOS` v33 stored                                     |
| verifier for v0.33.0        | `0x48D218eF4FFFDAbB12df32B578edCCF5B9892653` | `ZKsyncOSTestnetVerifier`, VK `0x29651d5f…`                                         |
| bridgehub admin / CTM admin | `0x7cbdDA00285de05a1353803db38770043e359B6d` | ChainAdmin                                                                          |

Chains on the ZKsync OS CTM that are on v0.33.0, all settling on L1 and each behind an EOA-owned ChainAdmin:
1913, 4221, 42111, 88288, 579029, 8022833, 8022834. 1401 is still on v0.31.1 and the other chains on
v0.29/v0.30; a cut keyed to v0.33.0 cannot apply to them.

Two inputs in `../../testnet.toml` differ from stage:

- `chain_creation_params_block`: the v33 upgrade called `setChainCreationParams` before `setNewVersionUpgrade`,
  so the CTM recorded the block of its last `NewChainCreationParams` (11667464) under v0.31.1, and
  `newChainCreationParamsBlock(v0.33.0)` is 0. The script reads the event at the given block and checks it
  against the CTM's stored hashes. `createNewVerifierOnlyUpgrade` copies the 0 forward to v0.33.2, so tools
  that look the params up by the current version keep finding nothing on testnet.
- `pre_v32_introspection = false`: the bridgehub's first chain (8022832) is on v0.29, which the address
  introspection would otherwise take to mean the whole ecosystem predates v32.

## Deployed on Sepolia

The four contracts were deployed on 2026-10-16 with `deploy.sh testnet` (hashes in `transactions.txt`) and
are source-verified on Etherscan. They are inert until the emergency proposal names them.

| contract                  | address                                      | deploy tx     |
| ------------------------- | -------------------------------------------- | ------------- |
| `ZKsyncOSVerifierPlonk`   | `0xfBA4D59ee044305C1916F87E98BbfD7Ee785e3b1` | `0x0320a7d6…` |
| `ZKsyncOSTestnetVerifier` | `0x9308Cc5518feFf18EdFf1B4937F042034CD9dcA1` | `0xefb08ba6…` |
| `UpgradeStageValidator`   | `0xC04FC5Ed2fFD03b27E953afe4020fAC1e2f0f885` | `0x050e0f78…` |
| `GovernanceUpgradeTimer`  | `0x8041C49aefbA4c0f96AF9dB80Ca76139E69c925E` | `0xf7c60b58…` |

On chain, `verificationKeyHash()` of `0x9308Cc55…` is `0xec24ed29…` and `IS_TESTNET_VERIFIER()` is true; the
timer's `TIMER_GOVERNANCE` and owner are the ProtocolUpgradeHandler. `UpgradeStageValidator` was verified
directly; the other three were matched by Etherscan to identical bytecode it had already verified.

## Executing it

1. Deploy: done.
2. Governance: **done on 2026-10-19**, one emergency proposal per stage: stage 0 at block 11947773 (tx
   `0x92c76054…`), stage 1 at 11947835 (`0x5db4f943…`, starting with the repeated `pauseMigration`) and
   stage 2 at 11947839 (`0x109a8f3e…`). The CTM is on v0.33.2 and migrations are unpaused.
   [`EXECUTE.md`](EXECUTE.md) lists the three proposals, each 12 `approveHash` txs then
   `executeEmergencyUpgrade`. Before stage 1 carried the repeated pause, stage 1 on its own reverted with
   `MigrationsNotPaused` (reproduced on a fork at block 11947772).
3. Per chain, once the v0.33.2 prover is live and the chain has no unexecuted batches, the ChainAdmin's owner
   follows `chain-upgrades/<id>/EXECUTE.md`: `01_*` (`setUpgradeTimestamp`), then `02_*` (the cut). See
   [`chain-upgrades/README.md`](./chain-upgrades/README.md).

## Validation

| check                                                                                  | result                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| deployed VK vs `zksync-os/latest.json` (asserted by the script)                        | `0xec24ed29…`, also on the live `0x9308Cc55…`                                                                                                                                                                                                                                                                                                                                             |
| `generate.sh testnet` (`FORK_BLOCK=11926704`), the pipeline's `rehearse-upgrade`       | `ecosystem.toml`, `execution.json` (the emergency proposal) and the ecosystem scenario reproduced byte for byte; `rehearse.sh` passes as its `verify_fork`                                                                                                                                                                                                                                |
| `EXECUTE.md` replay (`protocol_ops dev execution-runbook --check-fork-url`)            | all 13 emergency txs succeed on a Sepolia fork                                                                                                                                                                                                                                                                                                                                            |
| `rehearse.sh testnet` on a Sepolia fork (block 11926765), against the live deployments | `REHEARSAL PASSED` (46 checks): the 13 emergency txs succeed and carry exactly stages 0-2 of `[governance_calls]`; CTM on v0.33.2 with the new verifier and stored cut, creation params unchanged, migrations unpaused; chain 1913 (idle) upgrades through its committed bundles, the six chains with batches in flight refuse with `NotAllBatchesExecuted`; chain 556 created on v0.33.2 |
| per-chain bundles                                                                      | every cut byte-identical to `[chain_upgrades.<id>].chain_admin_calldata`; every timestamp bundle exactly `multicall([ServerNotifier.setUpgradeTimestamp(id, 1)])`                                                                                                                                                                                                                         |
| transaction-simulator `yarn simulate --ci` on all eight scenarios, one fork            | `✅ All simulations succeed!` for each: the ecosystem file, then all seven chains taking the timestamp and the cut                                                                                                                                                                                                                                                                        |

The scenarios' governance calls are sent by the ProtocolUpgradeHandler, which is the testnet owner the
simulator's era-contracts copy-paste check expects, so they can be registered in `era-contracts-provenance.json`
once this artifact is on a matter-labs/era-contracts branch.
