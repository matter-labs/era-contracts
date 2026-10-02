# Upgrade scripts

The Forge scripts in this directory prepare a protocol release for an existing ecosystem: they
deploy the new implementations, build the diamond cut and the L2 upgrade transaction, and
serialize the governance calls. The pipeline they are part of, the artifacts they produce and the
phases that follow (deploy, verify, governance ceremony, per-chain upgrades) are described in
[protocol-docs/ecosystem-upgrade.md](../../../protocol-docs/ecosystem-upgrade.md); this file only
covers the scripts themselves.

The scripts are not run with `forge script` directly in a rollout. `protocol_ops` (see
[protocol-ops/README.md](../../../protocol-ops/README.md)) invokes their entry points on an Anvil
fork and turns the recorded broadcasts into Safe bundles. `ecosystem upgrade-prepare-all` calls
`CoreUpgrade_v<N>.noGovernancePrepare` once and `CTMUpgrade_v<N>.noGovernancePrepare` once per
CTM; `chain upgrade` and `chain set-upgrade-timestamp` go through `AdminFunctions.s.sol`.

## Layout

| Path                                                                                                                                                                                    | Purpose                                                                                                                                                                                                                                                                                         |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `default-upgrade/DefaultCoreUpgrade.s.sol`                                                                                                                                              | The ecosystem-wide half every release runs: refreshes all core implementations, assembles the core calls of governance stages 0, 1 and 2. Releases override the `deployVersionSpecific…` and `prepareVersionSpecificStage…` hooks.                                                              |
| `default-upgrade/DefaultCTMUpgrade.s.sol`                                                                                                                                               | The per-CTM half: CTM-side implementations, stage validator and governance timer, force deployments, L2 upgrade transaction, diamond cut, CTM stage calls. Releases override `deployUsedUpgradeContract` and the additional-force-deployment hooks.                                             |
| `default-upgrade/CTMUpgradeBase.sol`, `DefaultL2UpgradeStrategy.sol`, `EraForceDeploymentsLib.sol`, `FacetCutsLib.sol`, `UpgradeHelperLib.sol`, `UpgradeParams.sol`, `UpgradeUtils.sol` | Shared building blocks of the two scripts above: cut generation, L2 upgrade transaction composition, facet cuts, parameter structs.                                                                                                                                                             |
| `default-upgrade/DefaultChainUpgrade.s.sol`                                                                                                                                             | Per-chain cut driver used by tests and by hand; the rollout uses `AdminFunctions.s.sol`.                                                                                                                                                                                                        |
| `default-upgrade/DefaultGatewayUpgrade.s.sol`                                                                                                                                           | The Gateway-side upgrade script, base of `gateway/GatewayVotePreparation.s.sol`. Its gateway deploys are disabled in v33, and it uses Era bytecodes directly, so it is not ZKsync OS compatible (see its "consider deleting" FIXME).                                                            |
| `default-upgrade/BridgedOutPopulationLib.sol`, `PopulateBridgedOut.s.sol` (the latter in this directory)                                                                                | The v33 post-governance `bridgedOut` population (`ecosystem stage3`) and its standalone entry point for resuming it.                                                                                                                                                                            |
| `v33/`                                                                                                                                                                                  | The current release's overrides: `CoreUpgrade_v33`, `CTMUpgrade_v33`, and `RecordPriorityOpLowerBound` (the per-chain precondition of the v33 cut).                                                                                                                                             |
| `SystemContractsProcessing.s.sol`                                                                                                                                                       | The list of L2 built-ins a release force-deploys, and the neutralizations of removed ones.                                                                                                                                                                                                      |
| `FinalizeUpgrade.s.sol`                                                                                                                                                                 | Post-upgrade initialization helper from older releases (chains and tokens); kept for the environments that still need it.                                                                                                                                                                       |
| `ValidatorTimelockUpgrade.sol`, `DecentralizeGovernanceUpgradeScript.s.sol`, `AppendProtocolUpgradeHandlerUpgrade.s.sol`                                                                | One-off governance helpers: a `ValidatorTimelock` implementation upgrade plus its shared-validator and signing-set calls, a CTM implementation upgrade and pending-admin change through the legacy `Governance`, and appending a `ProtocolUpgradeHandler` implementation upgrade to a proposal. |
| `EmergencyStageUpgradeCalldata.s.sol`, `EmergencyValidatorTimelockRestore.s.sol`                                                                                                        | Emergency-path calldata for the stage environment: executing the governance stages through the emergency upgrade board, and a one-off emergency upgrade.                                                                                                                                        |
| `SecurityCouncilApproveStageUpgrade.s.sol`, `SecurityCouncilEmergencyStageUpgrade.s.sol`                                                                                                | Not calldata emitters: both sign and send with `PRIVATE_KEY` against the stage `ProtocolUpgradeHandler`. The first is a normal-path Security Council approval of an upgrade id; the second executes an empty emergency upgrade.                                                                 |
| `VerifyStage1Pause.s.sol`, `VerifyEmergencyApproveHash.s.sol`                                                                                                                           | Fork-only checks that the emergency path executes end to end.                                                                                                                                                                                                                                   |

## Adding a release

1. Create `v<N>/CoreUpgrade_v<N>.s.sol` extending `DefaultCoreUpgrade` and
   `v<N>/CTMUpgrade_v<N>.s.sol` extending `DefaultCTMUpgrade`. Start from the previous release's
   files and keep only the overrides the new release needs: everything a release does not change
   is already in the default scripts, and a hook left empty is the intended way to say "nothing
   version-specific here".
2. Point `deployUsedUpgradeContract` at the release's per-chain upgrade contract
   (`l1-contracts/contracts/upgrades/`): the generic `DefaultUpgradeZKsyncOS` when the release
   has no one-time work, a one-shot `V<N>Upgrade…` otherwise. In the latter case also deploy a
   generic one and assign it to `ctmStoredDefaultUpgrade` (as `CTMUpgrade_v33` does), otherwise
   the CTM stores the one-shot contract as its `defaultUpgrade`.
3. Register new L2 built-ins in `SystemContractsProcessing.s.sol` and, for the genesis path, in
   the genesis generator, so that upgraded and freshly created chains match
   (`docs/ai-review/docs/genesis-and-upgrades.md`).
4. Create `l1-contracts/upgrade-envs/v<release>/` with one input TOML per environment and move
   `UPGRADE_ENV_DIR` in `protocol-ops/src/common/env_config.rs` to it; add the verifier
   expectations under `protocol-ops/src/upgrade_verification/versions/v<N>/`.
5. Rotate the CREATE2 salts in the input TOMLs before every regeneration, build with the default
   Foundry profile, and rehearse with
   `l1-contracts/test/anvil-interop/regen-upgrade-calldata.sh <env>` before broadcasting anything.
   `l1-contracts/upgrade-envs/v0.33.0-atomic-interop/output/testnet/README.md` documents one
   complete rollout.

A patch release that touches only some contracts follows the same shape: the default scripts
refresh every implementation regardless, which is what keeps the deployed contracts equal to the
release branch, and the release-specific hooks stay empty.

## Rules

- Never use `try`/`catch` or `staticcall` in these scripts. A revert means the script is being
  run at the wrong time or against the wrong state; fix that instead of masking it.
- Read addresses from L1 (through the Bridgehub) rather than adding input fields; the inputs a
  release needs are listed in `upgrade-envs/README.md`.
- Every release ships with the anvil-interop upgrade test (`test/anvil-interop/docs/upgrade-test-runner.md`),
  which runs these scripts end to end on the previous release's chain states.
