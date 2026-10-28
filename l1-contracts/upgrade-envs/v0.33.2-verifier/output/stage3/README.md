# v0.33.2 — stage3

The atomic-interop stage ecosystem deployed from `release/v0.33.0-atomic-interop` on 2026-08-27, "stage3" in
`AGENTS.md`; its permanent values are `../../permanent-values/stage3.toml`. It is **not** the older stage
ecosystem that `../../v0.33.0-atomic-interop/stage.toml` and `permanent-values/stage.toml` describe (bridgehub
`0x236D1c3F…`, owned by the stage ProtocolUpgradeHandler). Everything below was read from Sepolia.

| what                        | address                                      | notes                                                                  |
| --------------------------- | -------------------------------------------- | ---------------------------------------------------------------------- |
| Bridgehub                   | `0xb9415d43C7753cCeBaa1ac05c8BabA36159ab13F` |                                                                        |
| ZKsync OS CTM               | `0x94d8784d719181EA00f58ab4a85333959FFA5a79` | `isZKsyncOS() == true`, the only CTM on this bridgehub                 |
| ChainAssetHandler           | `0x33388639Ba3f30AD47fc6e6769CEe89e53a09991` | holds `pauseMigration` / `unpauseMigration`                            |
| Governance                  | `0xFF657F253C0FbdE6A7DeCdc958F4153C1179D3aa` | owns the CTM and the ChainAssetHandler; `minDelay() == 0`              |
| Governance owner            | `0xd2d5391421f98A0086F4143D2EA0337a31Ca89E5` | EOA; also the security council and the owner of every ChainAdmin below |
| CTM `defaultUpgrade`        | `0x142d4EaBBA644907b6C51b08b19684e40de3dCC4` | byte-identical to this branch's `DefaultUpgradeZKsyncOS`               |
| verifier for v0.33.0        | `0x23461C3EF806ea8e87e88A6DA584C84f884A3055` | `ZKsyncOSTestnetVerifier`                                              |
| bridgehub admin / CTM admin | `0xa95BaE85Fd551603f9ddAfD1827aC11fab6971C0` | `ChainAdminOwnable`                                                    |

Chains, all on v0.33.0 when the artifact was made and settling on Sepolia, each behind its own
`ChainAdminOwnable`: 2727, 2728, 2729, 27271, 27272, 27273. Chain 2727 has never committed a batch and still
carries the production verifier `0x2aEa8C51…` from the original deployment.

## Status

**Executed.** The governance stages ran on 2026-10-06 (the CTM's `NewProtocolVersion` at block 11855311, tx
`0xb2f19079…`); the CTM is on v0.33.2 with the new verifier. Chains 27271 and 27273 have taken their cut;
2727, 2728, 2729 and 27272 are still on v0.33.0 (as of 2026-10-16). `prepare` therefore no longer runs
against live stage3: it requires the CTM on v0.33.0. To reproduce the artifact, fork Sepolia before the first
deployment (block 11854783): the generate-ecosystem-upgrade-calldata workflow with
`upgrade=v0.33.2-verifier`, `environment=stage3`, `fork_block=11854782` and
`deployer_address=0xd2d5391421f98A0086F4143D2EA0337a31Ca89E5`, or `rehearse-upgrade` with the same values
locally. Both reproduce `ecosystem.toml`, `execution.json` and `EXECUTE.md` byte for byte.

`test_create_chain_zkos` names the script's sender as the test chain's admin (`DefaultCTMUpgrade`), so it
follows the deployer the pipeline runs as; the artifact first generated on 2026-10-05 named forge's default
sender there. The governance calls, the only calls executed, are unchanged.

## Deployed on Sepolia

The four contracts were deployed on 2026-10-06 with `deploy.sh stage` and are source-verified on Etherscan.
Hashes are in `transactions.txt`.

| contract                  | address                                      | deploy tx     |
| ------------------------- | -------------------------------------------- | ------------- |
| `ZKsyncOSVerifierPlonk`   | `0xB548D8028a82A635C6E506f7045FE29F331C897c` | `0x04346299…` |
| `ZKsyncOSTestnetVerifier` | `0x5130E7D98b45E50dD059B1Ffc870077be49EBef6` | `0xc14cfab5…` |
| `UpgradeStageValidator`   | `0xd4cf05E557C28eC06952dB961Bd371a254223014` | `0xd8b38c2e…` |
| `GovernanceUpgradeTimer`  | `0xa1FAdE7c8863D9f6ebF59B25b0C693b291ecd9d4` | `0x33aa5c11…` |

On chain, `verificationKeyHash()` of `0x5130E7D9…` is `0xec24ed29…` and `IS_TESTNET_VERIFIER()` is true.
`ZKsyncOSTestnetVerifier` and `GovernanceUpgradeTimer` were matched by Etherscan to identical bytecode it had
already verified.

## Executing it

1. Deploy: done.
2. Governance: done. As the Governance owner, the six txs of [`EXECUTE.md`](EXECUTE.md):
   `stageN_schedule_calldata` then `stageN_execute_calldata` to the Governance for N = 0, 1, 2
   (`[governance_operations]`; `yarn execute-governance-instant` in the transaction-simulator sends the same
   transactions).
3. Per chain, once the v0.33.2 prover is live and the chain has no unexecuted batches, the ChainAdmin's owner
   executes `chain-upgrades/<id>/01_*` (`setUpgradeTimestamp`), then `02_*` (the cut).

## Validation (before execution)

| check                                                                                | result                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| creation bytecode of the verifier contracts vs `AllContractsHashes.json`             | identical                                                                                                                                                                                                                                                                                     |
| deployed VK vs `zksync-os/latest.json` (asserted by the script)                      | `0xec24ed29…`, also on the live `0x5130E7D9…`                                                                                                                                                                                                                                                 |
| `rehearse.sh stage` on a Sepolia fork (block 11854801), against the live deployments | `REHEARSAL PASSED`: CTM on v0.33.2 with the new verifier and stored cut, creation params unchanged, migrations unpaused; the committed chain bundles upgrade every chain idle at that block (2727, 2728, 27271), the others refuse with `NotAllBatchesExecuted`; chain 556 created on v0.33.2 |
| per-chain cut bundles vs `[chain_upgrades.<id>].chain_admin_calldata`                | byte-identical, all six                                                                                                                                                                                                                                                                       |
| transaction-simulator `yarn simulate --ci` on all seven scenarios, one fork          | `✅ All simulations succeed!` for each: the ecosystem file, then all six chains taking the timestamp and the cut                                                                                                                                                                              |

The simulator's era-contracts copy-paste check hardcodes stage's owner as the old ProtocolUpgradeHandler
`0x8f086275…`, so registering these files in `era-contracts-provenance.json` also needs this ecosystem's
Governance there. The transaction-simulator's copies (merged in its #374) are named `…-stage-…`, after the env's
earlier name, and name the earlier test chain admin.
