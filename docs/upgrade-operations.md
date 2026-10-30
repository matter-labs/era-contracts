# Upgrade operations: operational policies

Companion to [registry-driven-upgrades.md](registry-driven-upgrades.md). Execution is specified in
[`protocol-docs/ecosystem-upgrade-coordination.md`](../protocol-docs/ecosystem-upgrade-coordination.md);
the objects, executors and bootstrap are in the architecture document; the tooling is in
[the runbook](../l1-contracts/deploy-scripts/upgrade/README.md). This document holds the
operational policies none of those owns.

## ServerNotifier: a one-time handover, then an ordinary CTM-domain proxy

The notifier is a per-CTM proxy. Pre-v35 deployments put it under its OWN `ProxyAdmin`, owned by
the CTM's `ChainAdmin`, and nominated the `ChainAdmin` as its owner. From the registry bootstrap on
it is administered like the rest of the CTM domain: its proxy sits under the CTM-domain `ProxyAdmin`
the CTM executor owns, the CTM executor owns the notifier itself, and its implementation swaps are
ordinary rows of a CTM-domain `ProxyUpgradeTransition`. A fresh ecosystem is deployed in that shape
already: `DeployCTM` puts the notifier under the CTM-domain `ProxyAdmin` and hands it to the CTM
executor.

Getting there is a one-time handover and a PRECONDITION of the bootstrap, because governance cannot
perform the ChainAdmin's half:

| step | authority                                                                 | call                                                                    |
| ---- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| 1    | owner of the notifier's old `ProxyAdmin`                                  | `changeProxyAdmin(notifier, ctmProxyAdmin)`                             |
| 2    | the notifier's current owner                                              | `transferOwnership(ctmExecutor)`                                        |
| 3    | the CTM executor's owner (governance), first call of the bootstrap bundle | `ctmExecutor.forward([notifier.acceptOwnership()])`                     |
| 4    | the bootstrap bundle                                                      | `migrate()` swaps the notifier's implementation through `ctmProxyAdmin` |

Steps 1–2 are RENDERED from live state by the bootstrap prepare
(`CTMUpgrade_v35.serverNotifierHandoverCalls`, a step already done is left out), written to the
prepare output's `[ctm_admin_calls].server_notifier_handover`, declared as `admin`-phase external
actions, and run by protocol-ops right after the prepares (`UpgradeFull::run_ctm_admin_steps`). Step
3 is derived only while the notifier is not yet the executor's, so the bootstrap bundle reverts
until steps 1–2 landed, and step 3 itself reverts unless the CTM executor is the nominee.
`RegistryBootstrapMigration.validate()` refuses to run unless the manifest's mandatory notifier row
names the CTM's notifier, the notifier serves the CTM and is owned by the CTM executor with no
nomination outstanding, and the notifier's row applies only through `ctmProxyAdmin`;
`validateApplied()` keeps checking the ownership and the binding. `protocol-ops ecosystem
verify-bootstrap` reports the handover as its own prerequisite.

The handover is not undone if the bootstrap is cancelled afterwards: the notifier then simply
belongs to the CTM domain early. A recurring prepare has no admin calls.

## Executor succession

Each domain executor is bound by immutables to what it governs (`CoreUpgradeExecutor.PROXY_ADMIN`;
`CTMUpgradeExecutor.CHAIN_TYPE_MANAGER` and `CTM_PROXY_ADMIN`), and nothing names an executor in
return. Replacing one is therefore a handover of its domain to a successor constructed over the
same bindings and owned by governance, through the predecessor's `forward`:

- the core domain: `ProxyAdmin.transferOwnership(successor)` on the ecosystem `ProxyAdmin`;
- a CTM domain: `transferOwnership(successor)` on the CTM, its `ProxyAdmin` and the ServerNotifier;
  the successor's `acceptCTMOwnership()` (called by governance, the successor's owner, or by the
  predecessor in the same `forward`) and a `forward([notifier.acceptOwnership()])` complete the
  two-step handovers.

Hand over before preparing the next upgrade: the prepares name the executor that holds each domain
at prepare time (the ecosystem `ProxyAdmin`'s owner, the CTM's owner), and the merge derives the
legs on it. A leg sent to an executor that no longer holds its domain reverts, and the whole
proposal with it. Package verification re-derives an executor from its `[upgrade_executors]`
record, so the successor's deployment must leave one (see "Provenance and validation" in the
architecture document).

## Monitoring

- **`L1UpgradeApplied(coreTransition)`** on the core executor, and
  **`CTMInfrastructureUpgradeApplied(infrastructureTransition)`** and
  **`CTMUpgradeApplied(transition, oldVersion, newVersion)`** on the CTM executor: each must name an
  object governance approved, and the legs of one upgrade appear in one transaction — the execution
  of its governance proposal — in canonical order. `ProxyImplementationUpgraded(proxy, newImpl)`
  follows each actual swap. A leg in any other transaction, or a proposal carrying only part of a
  package's legs, is not the reviewed upgrade.
- **`CallForwarded(target, value, data)`** on both executors. Every owner operation outside the
  upgrade entrypoints is a `forward` (see the authority matrix in the architecture document), so each
  event must match a call governance approved; anything else is a bypass of the object-driven path.
  The one exception is a chain's `Freeze` / `Unfreeze` without a `CallForwarded`: the Bridgehub's
  owner freezing directly, as the Security Council's freeze does
  ([freezing a chain](../protocol-docs/ecosystem-upgrade-coordination.md#freezing-a-chain)).
- **Ownership changes** (`OwnershipTransferStarted` / `OwnershipTransferred`) on the executors, the
  CTM, both `ProxyAdmin`s, the ServerNotifier and the Bridgehub (whose owner can freeze the CTM's
  chains): expected only during executor succession or
  [governance self-migration](governance-self-migration.md).

## Recovery

A governance proposal either executes completely or reverts; nothing is left pending. What an
executed upgrade committed stands until a later change replaces it.

**An urgent fix** is a proposal of the one call it needs:

- an ecosystem implementation: `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)`;
- a CTM-domain implementation: `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)`;
- any other CTM-domain change, such as a CTM owner call: `CTMUpgradeExecutor.forward`;
- a defective transition already committed for a departed version:
  `ChainTypeManager.replaceUpgradeTransition` through `forward` (see "Replacing a committed
  transition" in the coordination spec).

An upgrade prepared before such a fix still executes only if every row still departs from the live
implementation (or already runs its `implNew`) and its transition still departs from the CTM's live
release and version; otherwise its leg reverts (`ProxyUpgradeRowMismatch`, or the transition's edge
check), the whole proposal with it, and the upgrade is prepared again against the fixed state.

## Migration pauses are incident control

`L1ChainAssetHandler` keeps two migration pauses: the ecosystem-wide `pauseMigration` /
`unpauseMigration` of its owner (governance), and the per-CTM `pauseCTMMigration(ctm)` /
`unpauseCTMMigration(ctm)` of that CTM's current owner — its `CTMUpgradeExecutor`, so governance
reaches it through `forward`. No upgrade path sets or requires either. Where the release-level
migrations ban applies
([chain lifecycle](../protocol-docs/chain-lifecycle.md#v33-chain-migrations-are-explicitly-disabled)),
a migration is refused before either pause is consulted.

## Deployer signing

The deployer EOA signs the prepare's deployer Safe files (`upgrade-broadcast`). Neither the bundle's
digests (`verify-bundle`) nor `verify-bootstrap`, which reads deployed objects, constrain that
transaction list, so `protocol_ops ecosystem check-deployer-plan` holds it to the deploy checkout
and to L1 before the key is used. Every call of a bundle whose signer is the deployer must send no
value and be either

- a CREATE2 deployment through the env's `create2_factory_addr` (the deterministic deployment
  proxy), under the env's `[contracts] create2_factory_salt` or a `[create2_factory_salts]` entry,
  whose address and init code are reviewed-build creation code plus: a `[member_deployments]`
  record's constructor arguments; an `[upgrade_executors]` record's (initial owner = the env's
  `owner_address`, and a CTM executor's CTM one of the env's); an exact ABI encoding of the
  constructor's parameters for an object a `[registry]` key names; the bootstrap sequence's (the
  package's migration and core transition); or, for a `TransparentUpgradeableProxy` the package
  names, a recorded implementation and the ecosystem `ProxyAdmin` or a CTM's `ProxyAdmin` on L1; or
- a call on the reviewed allowlist (`ALLOWLIST` in
  `protocol-ops/src/commands/ecosystem/deployer_plan.rs`), every entry taken from the v35 bootstrap
  prepare's deployer bundle:

| call                                        | target (package)                                                                                          | constraint                                                                                 | emitted by                                                     |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| `transferOwnership(address)`                | the CTM, its `ValidatorTimelock`, its `ProxyAdmin` (its EIP-1967 admin on L1), the ecosystem `ProxyAdmin` | new owner is the env's `owner_address`                                                     | `ensureCtmsAndProxyAdminsOwnedByGovernance`, deployer as owner |
| `publishEVMBytecodes(bytes[])`              | the CTM's `bytecodes_supplier_addr`, which must be its `L1_BYTECODES_SUPPLIER()` on L1                    | none: publishing is permissionless                                                         | `BytecodePublisher` in the CTM prepare                         |
| `multicall((address,uint256,bytes)[],bool)` | `[ctm_admin_calls] chain_admin`                                                                           | requires success; every call sends no value and is one of the two rows below               | the ServerNotifier handover through a ChainAdmin               |
| `transferOwnership(address)`                | an `admin`-phase `[[external_actions]]` target                                                            | exactly that declared call, nominating the CTM executor this plan deploys                  | the ServerNotifier handover, deployer as owner                 |
| `changeProxyAdmin(address,address)`         | an `admin`-phase `[[external_actions]]` target                                                            | exactly that declared call, to the `ProxyAdmin` that administers that executor's CTM on L1 | the ServerNotifier handover, deployer as owner                 |

A role that belongs to a CTM (the CTM, its `ValidatorTimelock`, `ProxyAdmin`, `BytecodesSupplier`
and `ctm_admin_calls` ChainAdmin) counts only in a `[ctms.<key>]` table whose
`chain_type_manager_proxy` is one of the env's `[[ctm_contracts.ctms]]`; a table naming such a role
without a CTM is refused. The CTMs' `ProxyAdmin`, `BytecodesSupplier` and `ValidatorTimelock`
(`validatorTimelockPostV29()`), and the ecosystem `ProxyAdmin` (the EIP-1967 admin of the env's
`bridgehub_proxy_addr`), are read over `--l1-rpc-url`
(`replay-bundle` passes its `--rpc`, or in a rehearsal the fork it replays on), never taken from the
bundle. Without `--env` or `--bundle`, the package's own CTMs and Bridgehub stand in for the env's.

A refusal names the call's index, Safe file, target, selector and value. A prepare that needs
another call extends the allowlist in review. The package's other addresses and records come from
the bundle; the salts, factory, governance owner, CTM list and creation code come from the
checkout. Constructor arguments, a proxy's initializer and published bytecode are not judged here:
`verify-bootstrap` holds what they build before governance signs.

For a bundle (`--bundle`, and `replay-bundle`), the reviewed inputs are those of the upgrade the
bundle names: `prepare-all` is the release's own directory, and a `forge-script` upgrade whose
deployer signs anything declares its salts and owner in its own `upgrade-envs/<upgrade>/<env>.toml`
and records its deployments in `[member_deployments]` like a prepare does; nothing is skipped by
upgrade kind. The env's `l1_chain_id` must equal the bundle's `l1.chain_id` and the RPC's chain id.
A bundle in which the deployer signs nothing passes. A release input declaring
`redeploy_zk_governance = true` is refused: the PUH/Guardians redeploy deploys under its own salt
from zk-governance artifacts, which the check does not know yet. Signing (`replay-bundle --key`, and
`check-deployer-plan --bundle`, which the deploy workflow runs) also requires this checkout to be
the bundle's `contracts_commit` with no change to the contract sources and reviewed inputs the
generation tracks, a bundle not marked `contracts_worktree_dirty`, and the build to be read from
this checkout.

It runs in the generate workflow's `verify-bundle-handoff` job and in every `replay-bundle` except
`--verify-only`; the deploy workflow runs it after selecting the L1 RPC and before the step that
reads the deployer key, and refuses to run on a commit other than the bundle's `contracts_commit`.
The anvil upgrade test runs it on every prepare it replays. `upgrade-broadcast` and
`dev execute-safe` check nothing: sign a bundle with `replay-bundle --key`, or run the check first.

**Proposal (not configured): a protected environment for the deploy job.** Anyone with write access
can dispatch `deploy-ecosystem-upgrade.yaml` from any ref, and that ref's code runs with
`DEPLOYER_PRIVATE_KEY_*`: the job declares no `environment:`. Move the deployer keys and L1 RPC
secrets from repository to environment secrets of one environment per L1 (`deploy-sepolia`,
`deploy-mainnet`), each with a deployment branch policy admitting only protected branches (`main`,
`release/*`, `draft/*`) and required reviewers (two for mainnet), and set `environment:` on the job
from the bundle's `l1.chain_id`, resolved in a preceding job that holds no secret. A run then waits
for a reviewer, and code from an unprotected ref never reaches a key; since a deploy must check out
the generation commit, the generation has to run from a protected branch too. The move also cuts
off `execute-deployer-safe-bundles.yaml`, which reads `DEPLOYER_PRIVATE_KEY_SEPOLIA` and
`DEPLOYER_PRIVATE_KEY_MAINNET` for any run's artifact with no plan, provenance or commit check;
until then it must not sign upgrade bundles.
