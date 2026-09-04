# L1 Interop Center

## Design

L1 sends use ERC-7786 `sendMessage` and ERC-7930 recipients. The required
`l1ToL2TransactionParams(mintValue, l2GasLimit, l2GasPerPubdataByteLimit, refundRecipient)`
attribute supplies priority-transaction parameters. Optional `interopCallValue`
sets destination value; `factoryDeps(bytes[])` supplies direct-call dependencies.
`indirectCall(uint256)` selects a source-side cross-chain sender and its ETH value.
The returned send ID is the canonical Mailbox priority-transaction hash.

- **Keep: priority-queue transport.** Deposit the base token, build the destination
  call, submit it to the Mailbox, then confirm the canonical hash with the sender.
  This preserves failed-deposit recovery. Replacing the queue with message-root
  transport is a separate release.
- **Keep: one-call bundles.** `sendBundle` accepts exactly one call and shares the
  send implementation. Transaction parameters and dependencies are bundle
  attributes; indirect-call and destination value are call attributes. Rejecting
  all bundles would lose the interface parity requested in PR #2271.
- **Change: minimize L2 sharing.** Put the contracts in `interop/interop-center/`
  and rename the current built-in to `L2InteropCenter`. Keep its implementation
  and storage-bearing inheritance unchanged. A common interface describes both layers; the L1
  base owns its pause and reentrancy wrappers. Moving L2 into the old PR's base
  risks changing storage, preview behavior and code size. L2 keeps its existing
  parser built-in and rejects the new L1-only attributes.
- **Keep: governance-owned L1 proxy.** Deploy with the existing TUPP mechanism,
  initialize with the deployer, then transfer ownership to ecosystem governance.
  Reject zero owners and lock the implementation against initialization. A
  built-in deployment is inappropriate for an L1 contract.
- **Keep: remove the Bridgehub request entry points.** This assumes the fresh
  v34 OS-only line has no external request consumers or external
  `IL1CrossChainSender` implementers. The repository contains three production
  implementers: L1AssetRouter, CTMDeploymentTracker and ChainRegistrationSender.
  Repository search cannot prove absence of external implementations; the
  assumption requires reviewer confirmation. One-release forwarding shims are
  the alternative if that assumption is overturned.
- **Keep: Bridgehub registry authorization.** Append `interopCenter` without
  moving existing storage. Mailbox and L1 senders resolve the authorized caller
  from this registry. Per-chain diamond storage would save a registry lookup
  but require another migration and introduce duplicated configuration.
  Measurements are recorded in `HANDOFF.md`.
- **Keep: interop vocabulary.** Use `initiateIndirectCall`,
  `confirmL2Transaction`, `IndirectCallRequest`, `INDIRECT_CALL_MAGIC_VALUE` and
  `MIN_CROSS_CHAIN_SENDER_ADDRESS`. Preserve the internal nullifier confirmation
  selector and historical protocol-ops decoding. Retaining the old user-facing
  vocabulary would leave two competing descriptions of the same send flow.
- **Change: recognize both send entry points in PermanentRestriction.** An
  asset-router recipient only identifies a migration when an actual
  `indirectCall` attribute is present. Apply this to `sendMessage` and one-call
  `sendBundle`; checking only `sendMessage`, as the old PR did, would leave the
  equivalent bundle entry point outside migration-admin protection. The expected
  asset handler is the registered `chainAssetHandler`, not Bridgehub; the current
  chain-migration payload is handled there.
- **Keep: exact funding and caller identity.** ETH base-token direct sends use
  exactly `mintValue`; indirect sends use `mintValue + indirectCallMessageValue`.
  Other base tokens require zero ETH for direct sends and exactly the indirect
  call's ETH value for indirect sends. The indirect priority sender remains the
  cross-chain sender, preserving Prividium's asset-router filtering.

`l2TransactionBaseCost` is available on L1InteropCenter. Existing internal
Bridgehub cost queries can remain as registry convenience methods. MessageSent
identifies the resolved destination-side recipient, including indirect sends.

Out of scope: the Era-only `Mailbox.requestL2Transaction` path (EVM-1668),
L2-to-L1 execution in L1InteropHandler, priority-queue replacement, fee-model
changes, and same-base-token funding changes (EVM-1395).

## Discovery against the current branch

Base: `cfbfd9231ed7033e8bb765650f9d8f83c37d679c`, a fresh full clone of
`draft/v0.34.0` (`--is-shallow-repository` is `false`). Prior implementation:
`630297df0e387a0bf1427941459611954bee74b3`; merge base:
`348eb744af5f678d6af35538d69fabecb4cfe1a5`. The current base has 511 commits since
that merge base, rather than the plan's 480. Separate historical diffs for
contracts, deployment scripts, tests and protocol-ops were produced for review;
the old L1InteropCenter implementation and its 22-test suite are the design and
test reference, not a branch to merge.

The L1 entry points, missing L1 attributes, Bridgehub split, dynamically resolved
refund handling, and three sender implementations match the plan. The current
refund helper returns both an address and a finality flag; the migration must
preserve the existing treatment of that flag. The Bridgehub base ends with a
36-slot reserved gap. No existing live slot may move.

PR #2454 is merged. The current genesis still declares protocol `0.32.0` and
execution version 5; `release/v0.33.0-atomic-interop` is not an ancestor. Upgrade
scripts currently have `default-upgrade/` and `v31/`, without a `v34/` directory.
The restored `v0.32.2` harness state is the protocol-v31 baseline, not v33.
Foundry v1.5.1, commit `b0a9dd9ce`, matches the installed upstream toolchain.

## Prior PR decisions

The design bullets above record the retained decisions and alternatives.
Additional dispositions: **drop** the attempted Era entry-point removal (the
prior PR reverted it); **drop** edits to removed EraVM workspaces and legacy
bridges; **change** deployment wiring to the current split Bridgehub and handler
precedent; **keep** canonical-hash confirmation and ChainRegistrationSender's
confirmation access check; **keep** historical ABI decoders for past upgrades;
**change** the old L2 refactor to a rename that preserves current atomic and
preview logic. Runtime size, storage-layout comparisons, gas measurements and
validation outcomes belong in `HANDOFF.md` once measured.

## Deployment and migration

Fresh ecosystems deploy a transparent upgradeable proxy, initialize it with the deployer,
transfer ownership to governance and register it with `Bridgehub.setInteropCenter`.
The ecosystem ownership-acceptance step completes the pending transfer to governance.
Deployment and upgrade TOML uses
`bridgehub.l1_interop_center_{implementation,proxy}_addr`.

The shared core upgrade flow (also exposed as `CoreUpgrade_v34`) deploys the proxy when
absent. Stage 1 upgrades Bridgehub, then accepts the center's ownership and sets the registry
before stage 2 can submit priority requests. The CTM upgrade regenerates the Mailbox facet.
For an ecosystem already using this surface, set `has_l1_interop_center = true` in the upgrade
inputs for both core and CTM preparation: discovery then reads the existing proxy and stage 1 upgrades its implementation.
The default is false for historical source chains whose Bridgehub has no getter; discovery
does not probe a missing method or suppress its revert.

ERC20 base-token approvals target the NativeTokenVault discovered through the asset router;
it pulls the request funding. Governance and chain-admin helpers retain the same caller
for approval and message submission.

No prior request selectors are forwarded. Integrators discover `interopCenter()` and migrate
to the attributes above. The original `BridgehubDepositFinalized` event remains the gateway
migration confirmation signal. The nullifier confirmation ABI and recovery data are unchanged.
Historical Rust decoders and hash-manifest labels remain supported; artifacts that contain
the center select the current message and governance-call layout.

`factoryDeps` is rejected on indirect sends even when its array is empty. Duplicate,
unknown and misplaced attributes revert. L2-only attributes remain unsupported on L1;
L1-only attributes remain unsupported by the L2 parser.

The handshake marker retains its original value:
`bytes32(uint256(keccak256("TWO_BRIDGES_MAGIC_VALUE")) - 1)`.
Only its Solidity identifier changes to `INDIRECT_CALL_MAGIC_VALUE`.
The upgrade output also records `bridgehub.l1_interop_center_new_proxy` so verification
can distinguish new CREATE2 provenance from an existing proxy's unchanged constructor.
