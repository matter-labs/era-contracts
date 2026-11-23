# v0.34.1 — Era verifier patch (stage, testnet3)

The provers moved to new keys: Boojum FFLONK `0x1249034b…` and Airbender `0x010341d9…`
(`eravm-airbender-verifier-v31.6.0`), from `configs/genesis/era/latest.json`. Both chains require both proofs, so once
their provers switch, every proof fails against the v0.34.0 verifier (FFLONK `0xd89b62ac…`, Airbender `0xe1ea2201…`).
This patch gives the Era CTM a verifier with the new keys as v0.34.1 and moves each chain to it. Nothing else changes:
no facets, no L2 upgrade transaction, no base-system hashes, no chain-creation params.

A key change on a live version must be a new patch: the node stores the keys per protocol patch and only submits proofs
matching the chain's verifier. `setProtocolVersionVerifier` would not do it: chains read the verifier only at upgrade or
creation.

| Environment                   | Status                                                                             |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| stage (Sepolia, chain 499)    | Generated, not deployed. Governance: one Emergency Upgrade Board proposal          |
| testnet3 (Sepolia, chain 312) | Generated, not deployed. Governance: the PUH's normal path, one proposal per stage |

- stage: `output/stage/` is generate run [45198144834](https://github.com/matter-labs/era-contracts/actions/runs/45198144834)
  (Sepolia block 12196440).
- testnet3: `output/testnet3/` is generate run
  [45198151963](https://github.com/matter-labs/era-contracts/actions/runs/45198151963) (Sepolia block 12196431).

## What changes

- **Deployments:** `EraVerifierFflonk`, `AirbenderVerifierPlonk`, `EraMultiProofTestnetVerifier` over both, and
  `DefaultUpgrade`, through CREATE2 with the env's salt. Only the multi-proof verifier has constructor args.
- **Governance:** stage 0 pauses migrations. Stage 1 pauses them again, then calls
  `CTM.createNewPatchUpgrade(v0.34.0, no deadline, v0.34.1, verifier, DefaultUpgrade)`. Stage 2 unpauses.
- **Per chain:** the ServerNotifier upgrade timestamp, then `upgradeChainFromVersion(diamond, v0.34.0, cut)`, which sets
  the chain's verifier to v0.34.1's and its version to v0.34.1. Both come from `protocol_ops chain` bundles; the output
  has no per-chain calls.

`createNewPatchUpgrade` builds the cut on chain (no facet cuts, `DefaultUpgrade` with an empty `ProposedUpgrade` for
v0.34.1), carries the creation params forward and registers the verifier. It reverts unless migrations are paused, and
every PUH proposal executed through the Board unpauses them first (as can anyone, with `PUH.reinforceUnfreeze()`), hence
the second pause in stage 1. The pause is the bridgehub's, so it holds migrations of every chain on the bridgehub until
stage 2. v0.34.0 keeps no deadline, so chains not yet upgraded keep committing.

`DefaultUpgrade`, not v34's `EraSettlementLayerV34Upgrade`: the latter reverts unless every committed batch is executed,
while the server upgrades a chain with batches still waiting for new-key proofs.

## Executing it

Follows `AGENTS.md`, "Executing Stage and Testnet Upgrades".

1. **Prerequisites (server and prover owners).** A Boojum prover build for v0.34.1 with the new keys, and Airbender
   provers on `eravm-airbender-verifier-v31.6.0`. Keep the v0.34.0 provers until their batches are proven. On testnet3
   the node must be core ≥ v33.1.0. Both chains require both proof systems, and a batch whose two proofs come from
   different patches matches neither verifier: agree the switch-over first, for example pause sealing until both
   pipelines have proven the same last batch, set the timestamp, stop old-key Airbender provers from claiming new
   batches, and resume.
2. **Deploy** the bundle with `deploy-ecosystem-upgrade.yaml`. `verify_chain` must pass and the contracts must be
   verified on Etherscan.
3. **Governance.**
   - stage: `output/stage/EXECUTE.md` (`approveHash` on each Board member Safe, then `executeEmergencyUpgrade`).
     Approvals can't be revoked and a fully approved proposal stays executable, so send them all and the execute in one
     sitting, once step 1 holds.
   - testnet3: one proposal per stage through the PUH's normal path; its L1 runbook comes from
     `protocol_ops dev execution-runbook --input <tx list> --env testnet3 --check-fork-url <l1-rpc>` at execution time.
     Execute the stages in order: nothing on chain stops stage 2 from running before stage 1, which would leave
     migrations paused. Stages 0 and 2 are a bare pause and unpause (executor and salt zero), so check that their
     proposal IDs are unused on the PUH (`upgradeState` 0) before proposing.

   Then require `CTM.protocolVersion() = 146028888065`, `protocolVersionVerifier(146028888065)` = the output's
   `verifier`, `upgradeCutHash(146028888064)` = `upgrade_cut_hash`, and migrations unpaused.

4. **Timestamp**, sent by the ChainAdmin's owner, from the bundle
   `protocol_ops chain set-upgrade-timestamp --env <env> --chain-id <id> --new-protocol-version 146028888065 --upgrade-timestamp 1 --l1-rpc-url <rpc> --out <dir>`
   writes. `1` means as soon as the node sees it. It reverts before governance. Afterwards the node's stored keys for
   (34, 1) must be both new ones.
5. **The chain upgrade**, once the server owners confirm that no prove transaction is in flight and the next batch to
   prove already has a v0.34.1 proof:
   - **testnet3, server path:** the node's operator, which proves on the ValidatorTimelock, sends
     `ValidatorTimelock.upgradeChainFromVersion` itself once the timestamp has passed. It needs `UPGRADER_ROLE` for the
     diamond; check with
     `cast call <timelock> 'hasRole(address,bytes32,address)(bool)' <diamond> $(cast keccak UPGRADER_ROLE) <operator>`.
   - **stage, and testnet3's fallback:** the ChainAdmin's owner sends the bundle
     `protocol_ops chain upgrade --env <env> --chain-id <id> --l1-rpc-url <rpc> --out <dir>` writes. Stage's node proves
     through an EraMultisigValidator (`0x7de6…3275`) whose deployed implementation has no `upgradeChainFromVersion`, so
     stage has no server path.
6. **Afterwards:** the chain is on v0.34.1 with the new verifier, batches keep being committed, proven with the new keys
   and executed. Then retire the old provers.

## Server side

- The new verifier's no-argument `verificationKeyHash()` returns the FFLONK key, which the node stores as the patch's
  snark-wrapper key; `verificationKeyHash(2)` is the Airbender key.
- The node learns about v0.34.1 only from the ServerNotifier's `UpgradeTimestampUpdated`, which can be emitted only
  between governance and the chain's upgrade.

## Files

- `<env>.toml`: versions and the testnet flag (checked against the CTM, so a run fails if live state moved since review),
  salt, chain ids, and the committed v0.34.0 output whose creation params the script checks against the CTM's hashes.
- `output/<env>/`: committed from the generate run.
- `rehearse.sh`: the fork checks behind `upgrade.toml`'s `verify_fork` and `verify_chain`; its header says what it checks
  and how to run it alone. It sends each chain's calls as the `protocol_ops chain` bundles do for an Ownable ChainAdmin
  (stage's and testnet3's).

Generating and deploying work as for every forge-script upgrade (`docs/ecosystem-upgrade-deploy.md`).

## Not covered by the checks

- Proving a real batch with the new keys. The Airbender key is checked end to end with the fixture proof
  (`AirbenderPlonkProofFixture.sol`); the FFLONK key only by its hash.
- Node and prover behaviour: the stored keys, the switch-over, and the server sending the upgrade.
- The PUH paths themselves (the L2 vote, `startUpgrade`, Council approvals); `rehearse.sh` sends the stages as the PUH.
