# Contracts Security Review Focus

Applies to ZKsync OS contracts, shared L1 contracts, genesis, deployment and upgrade tooling in this repository.

## Release scope

- ZKsync OS only. Era (EraVM) chains and the Era CTM receive nothing from v34 onward; an Era-only consequence of a
  change is not a finding.
- All chains settle on L1. Gateway is softly deprecated and chain migration is disabled
  (`CHAIN_MIGRATIONS_ENABLED = false` in `common/Config.sol`). Gateway-only and migration-only paths are not findings
  unless the change re-enables them.
- An L2 to L2 send must be atomic and an L2 to L1 send must be non-atomic (`InteropCenter`). Public L2 to L2 execution
  was removed: `L2InteropHandler` exposes only `executeAtomicBundle` and `verifyAtomicBundle`. Commit-based interop roots
  revert in `Executor`. Atomic interop settles on L1 only (`AtomicFlowManager._checkSettlementLayerIsL1`).
- `protocol-docs/` specifies the intended behavior. Accepted limitations are under "Known issues" in
  `protocol-docs/atomicity/security.md` and `protocol-docs/interop-gating.md`, and in the security notes of
  `protocol-docs/bridging.md`. A change that widens one of them is still a finding.

## Roles

- Governance (the Bridgehub owner) and the CTM owner (`CTMUpgradeExecutor` and `CoreUpgradeExecutor`, which can
  `forward` arbitrary calls) are fully trusted. Review their implementation: scheduling, timelocks, cancellation,
  ownership handovers and initialization, across new selectors, multicalls and encodings. Do not review their decisions.
- A chain admin (a `ChainAdmin` with restrictions such as `PermanentRestriction`) and the chain's validators are trusted
  for that chain only. Check that they cannot affect other chains, unrelated assets, shared escrow or shared settlement.
- The Bridgehub admin may create chains and register base-token asset IDs, nothing more.
- On L2, `ComplexUpgrader` and the bootloader are the privileged built-in callers.
- Everyone else is untrusted, including token contracts, custom asset handlers, message payloads, proofs and tooling
  inputs. Permissionless token registration (asset IDs are namespaced by the registrant) and L1 to L2 submission
  (through the chain's transaction filterer and deposit pause) are intentional.

## Funds and messages

- A successful credit must have the backing its route requires. Trace lock, burn, mint, release, failed-deposit claims,
  refunds and fees together. One chain or asset handler must not spend another chain's backing in the shared vault
  beyond the per-chain balance rules.
- Preserve sender, chain and asset identity through routers, forwarded calls and L1 to L2 address aliasing. A handler
  or tracker for one asset must not gain authority over another asset or the shared vault.
- Withdrawal, failed-deposit, bundle and refund identifiers must not be reusable across routes or chains.

## Settlement and validators

- `ValidatorTimelock` keeps commit, prove and execute roles separate and enforces `MultisigCommitter` thresholds. The
  execution delay is the larger of the global and per-chain delays; a chain admin can only raise its own.
- Commit requires an active protocol version (`protocolVersionIsActive`, the CTM deadline) and binds the chain-config
  hash and interop fee units into the batch commitment. Chain-config changes require no unverified batches. Prove and
  execute must refer to the same stored batch and full public input.
- Anyone can activate priority mode once its conditions hold. Its batches carry only L1 transactions, skip the interop
  fee and cannot be reverted; only the CTM owner can deactivate it. `permanentlyAllowPriorityMode` cannot be undone and
  locks fee parameters, the token multiplier, the pubdata pricing mode, the transaction filterer and L1 transaction
  filtering.
- Mailbox, Executor and Committer are freezable; Admin, Getters and Migrator are not. New or replaced facets must keep
  that split, and unfreeze must stay reachable.
- The `*TestnetVerifier` contracts revert on chain ID 1. Test-only verifiers and DA stand-ins must stay out of
  production deployment paths. Avail is validium-only. Permanent-rollup chains keep their DA validator pair and pubdata
  restrictions in `Admin`.

## Interop

- `enableInterop` in `L1MessageRoot` is one-way, and so is the second-proof-system requirement. Once a second proof
  system is required, disabling one needs the Bridgehub owner, while enabling stays with the chain admin
  (`setProofSystemStatus`). A chain whose balance backfill is pending has no balance cap. Chains without interop may use
  only the native token vault or the chain asset handler.
- Atomic flows check peer consent on send (`InteropCenter`) and on L1 registration (`ChainRegistrationSender`). Finality
  and timeout refunds are mutually exclusive: inclusion needs a batch timestamp at or before the deadline, and absence
  needs a root timestamp after it (`AtomicInteropProof`). Atomicity authorizes execution; it does not promise that each
  destination call succeeds.
- Interop fee units are proven at commit and charged at execute. The chain admin withdraws its prepaid balance, the
  sweep to `feeRecipient` is permissionless, and priority mode is the only exemption.

## Upgrades and genesis

- Registry upgrades bind releases, transitions and manifests by `manifestHash`. Treat source and target release,
  transition commitments, proxies, facets, implementations, upgrade engines and initialization data as one authority
  path.
- Registry executors delegatecall the upgrade engine that an approved transition pins (`ProxyUpgradeExecutorBase`).
  The engine runs with the executor's authority and storage: its `ProxyAdmin` and, in the CTM domain, the CTM and
  `ServerNotifier`. Review engine changes as governance-authority code. `forward` stays a plain call.
- Compare changed storage layouts with the base snapshots. Keep reserved slots and enum values, and check initializer
  replay.
- L2 built-ins have no constructors or immutables. Genesis (`L2GenesisForceDeploymentsHelper`) and upgrades
  (`L2InventoryLib`) must set their state and agree on fixed addresses, implementations and ownership.
  `L2WrappedBaseToken` and `L2AdminFactory` are not built-ins and do have constructors.
- System hooks check their immediate fixed-address caller and return empty success to an unauthorized caller instead
  of reverting (`protocol-docs/system/system-hooks.md`). Public entry points must not let anyone else reach a hook
  through that caller.
- `ServerNotifier.setUpgradeTimestamp` is only a signal to the node. The enforced boundary is the CTM protocol version
  deadline.
- In tooling (`protocol-ops`, deploy scripts, upgrade-env inputs), trace configuration, RPC data and paths to file
  writes, subprocesses and generated transactions. Outputs must be bound to the intended network, addresses, bytecode
  and signers.

## Generated files

Do not analyze or report findings in the contents of these reproducible generated outputs:

- `AllContractsHashes.json`
- `l1-contracts/selectors`
- `l1-contracts/zkstack-out/**/*.json`
- `configs/genesis/zksync-os/latest.json`
- `l1-contracts/test/anvil-interop/chain-states/v0.35.0/*.json.gz`
- `l1-contracts/test/anvil-interop/chain-states/v0.35.0/addresses.json`
- `l1-contracts/scripts/registry-manifests/v35-local.json`

The hashes, selectors, zkstack exports, genesis and chain-state outputs are regenerated and checked by
`pre-merge-checks`. The local registry manifest is regenerated and drift-checked by the anvil upgrade test.
Do not analyze their hex, bytecode or other generated contents, or report findings in those contents.

Only skip the listed v0.35.0 chain-state outputs while CI regenerates that version. Previous-release fixtures are
inputs to upgrade tests, not rebuilt outputs; keep them in scope.

Review the sources, generators, inputs and CI checks that produce and validate these outputs. Changes that weaken
regeneration or comparison checks remain in scope. Do not extend this list merely because a file looks generated.
Historical upgrade records, deployment configurations and other registry manifests remain in scope.

## Reporting

State the attacker role, configuration, affected assets or users and the broken invariant. Separate code-proven
behavior from deployment assumptions. Do not report claims that need a trusted role to misuse its documented powers.
