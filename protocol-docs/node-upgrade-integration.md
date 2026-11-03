# Node integration for registry-driven upgrades

From the v35 bootstrap edge on, the cut a chain crosses no longer embeds a `ProposedUpgrade`: its
init names a write-once object, and the L2 upgrade transaction is composed for each chain from that
object ([Flow: upgrading](../docs/registry-driven-upgrades.md#flow-upgrading)). This page lists what
a ZKsync OS node (the zksync-os-server upgrade watcher, its gatekeeper and its L1 sender) must do to
follow such an edge.

It is a rollout gate. No chain schedules a crossing of the bootstrap edge or of any later edge until
every node of that chain runs a server release that meets all of it (the
[runbook's node pre-flight](../l1-contracts/deploy-scripts/upgrade/README.md#7-chain-crossing)).

## The server today

At `zksync-os-server-private` `main` @ `4d808657c` (2026-10-16):

- The watcher decodes a cut's init only as `upgrade(ProposedUpgrade)` or `upgradeVerifierOnly`
  ([`upgrade.rs`][decode], called from [`upgrade_tx_watcher.rs`][watch]), and an error there panics
  the node ([`watcher.rs`][panic]). The first `UpgradeTimestampUpdated` of the bootstrap edge, or of
  any later edge, therefore stops every node of that chain.
- It locates the cut through `upgradeCutDataBlock` and falls back to the newest
  `NewUpgradeCutData(target)` log when that is 0 ([`upgrade.rs`][block],
  [`upgrade_tx_watcher.rs`][scan]). It composes the transaction through `getL2UpgradeTxData`, which
  the CTM no longer has ([`upgrade.rs`][getdata]).
- The gatekeeper reads the same cut data ([`upgrade_gatekeeper.rs`][gate]), and the L1 sender sends
  only the cut-taking `upgradeChainFromVersion` ([`upgrade_tx.rs`][send]).
- The upgrade integration tests call the cut-taking `setNewVersionUpgrade` with its pre-v35
  arguments ([`interfaces.rs`][itest]). They break once a departing layout's CTM is v35 or later.

## Requirements

1. **Resolve the edge by the version the chain departs from.**
   `UpgradeTimestampUpdated(chainId, protocolVersion, upgradeTimestamp)` carries the chain's current
   version, `old`. On the chain's CTM:
   - if `upgradeTransition(old)` is nonzero, the edge is a registry edge: the cut is
     `upgradeCutForVersion(old)`, and its init is `upgradeFromTransition(transition)` (`0x529334c4`);
   - otherwise the edge is legacy-committed, the v35 bootstrap included: the cut is the
     `NewUpgradeCutData` log in block `upgradeCutDataBlock(old)` whose `keccak256(abi.encode(cut))`
     is `upgradeCutHash(old)`. The bootstrap's init is `upgradeFromBootstrap(migration)`
     (`0xa419aa8f`); a pre-v35 edge's is `upgrade(ProposedUpgrade)`, handled as today.

   Never take the cut from the newest `NewUpgradeCutData(target)`. That event is keyed by the
   target, and a `replaceUpgradeTransition` that skips ahead commits a second cut under the same
   target from another departing version
   ([replacing a committed transition](./ecosystem-upgrade-coordination.md#replacing-a-committed-transition)).
   Never locate a registry edge through `upgradeCutDataBlock`, which is 0 for it. An init selector
   the node does not know is an error it reports, never a panic.

2. **Build the L2 transaction from the object, for this chain.** For a registry edge,
   `ICTMTransition(transition).l2UpgradeTx(bridgehub, chainId)`; for the bootstrap,
   `IRegistryBootstrapMigration(migration).l2UpgradeTx(chainId)`. `bridgehub` is the Bridgehub the
   chain is registered on. Each view returns the final transaction whose `keccak256(abi.encode(tx))`
   the diamond stores, with no per-chain rewrite after it. Both objects answer `upgradeTarget()` with
   the target version and the edge's `upgradeTimestamp`, before which the L1 crossing reverts. The
   factory dependencies are `tx.factoryDeps`, the plan's hashes. The preimage of each hash `h` is the
   `EVMBytecodePublished(h, bytecode)` log that the CTM's `L1_BYTECODES_SUPPLIER()` emitted in block
   `evmPublishingBlock(h)`. The CTM refuses to commit an edge whose dependencies are not published
   there, so every hash resolves.

3. **Accept the all-zero transaction.** A patch, and a minor edge that moves only L1 members, compose
   an all-zero transaction (`txType == 0`). The L1 crossing then records no upgrade transaction, and
   the chain's next batch must carry none. The node switches its protocol version without injecting
   a transaction, on a minor edge as on a patch.

4. **Resolve at execution.** A `replaceUpgradeTransition` can change the edge of a departing version
   after a chain has scheduled its crossing. Resolve requirements 1 and 2 when the transaction is
   injected, not when `UpgradeTimestampUpdated` arrives, and again before sending the L1 crossing,
   which is not sent while the edge composes a transaction other than the one the chain executed.
   The diamond's `UpgradeComplete(newProtocolVersion, l2UpgradeTxHash, l2ProtocolUpgradeTx)`, emitted
   by the crossing, records what L1 committed (a zero hash for none); a mismatch with what the chain
   executed halts the node with a diagnostic. After a replacement the runbook re-runs
   `setUpgradeTimestamp` for the chains that scheduled the replaced departure.

5. **Send the crossing the chain's facets take.** Through the `ValidatorTimelock` (`UPGRADER_ROLE`),
   a chain at v35 or later takes `upgradeChainFromVersion(address,uint256)` (`0x03129ad9`) and reads
   its cut from its CTM. Only a chain below v35, crossing the bootstrap edge, takes the cut-taking
   `upgradeChainFromVersion(address,uint256,DiamondCutData)` with the cut of requirement 1.

## Reference implementation

`tools/upgrade-readiness-checker` resolves the same edge per chain to find the transaction's receipt.
Port its per-chain resolution from
[`src/upgrade.rs`](../tools/upgrade-readiness-checker/src/upgrade.rs):

- `registry_edge_tx_hash`: a chain below the target reads
  `upgradeTransition(getProtocolVersion(chainId))`, requires it to land on the target and hashes its
  `l2UpgradeTx(bridgehub, chainId)`. A chain at or past the target takes the hash from its diamond's
  `UpgradeComplete(target)` (`recorded_upgrade_tx_hash`).
- `tx_hash_from_init_calldata`: the bootstrap's `l2UpgradeTx(chainId)`, and the legacy
  `ProposedUpgrade` with its per-chain data rewrite.
- `NO_L2_UPGRADE_TX`: an all-zero transaction is a reported outcome, never a wait.

The tests in the same file pin each branch, among them
`newest_registry_cut_is_not_taken_as_the_chains_edge`. The `sol!` declarations of the views it
reads are in [`src/abi.rs`](../tools/upgrade-readiness-checker/src/abi.rs); the rest are declared
in the contracts:
[`IChainTypeManager`](../l1-contracts/contracts/state-transition/IChainTypeManager.sol)
(`upgradeCutForVersion`, `upgradeCutHash`, `L1_BYTECODES_SUPPLIER`),
[`ChainTypeManager`](../l1-contracts/contracts/state-transition/ChainTypeManager.sol)
(`upgradeCutDataBlock`),
[`ICommittedUpgrade`](../l1-contracts/contracts/upgrades/registry/objects/ICommittedUpgrade.sol)
(`upgradeTarget`), [`BytecodesSupplier`](../l1-contracts/contracts/upgrades/BytecodesSupplier.sol)
(`evmPublishingBlock`, `EVMBytecodePublished`) and
[`IServerNotifier`](../l1-contracts/contracts/governance/IServerNotifier.sol)
(`UpgradeTimestampUpdated`). The checker is given a target,
so it reads the newest `NewUpgradeCutData(target)` only to tell the edge's kind. A node starts from
the departing version and resolves requirement 1 directly, with no log scan for a registry edge.

## Unchanged for the server

- The `GenesisUpgrade(address,L2CanonicalTransaction,uint256,bytes[])` event and its loader. Its
  `_factoryDeps` is now always empty, which is what the chain registration script already passed.
- `validatorTimelockPostV29()`. The removed `validatorTimelock()` has no server reader.

[decode]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/contract_interface/src/upgrade.rs#L81-L102
[watch]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/l1_watcher/src/upgrade_tx_watcher.rs#L136
[panic]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/l1_watcher/src/watcher.rs#L210-L212
[block]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/contract_interface/src/upgrade.rs#L32-L37
[scan]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/l1_watcher/src/upgrade_tx_watcher.rs#L195-L215
[getdata]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/contract_interface/src/upgrade.rs#L119-L125
[gate]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/l1_sender/src/upgrade_gatekeeper.rs#L314-L334
[send]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/lib/l1_sender/src/upgrade_tx.rs#L37
[itest]: https://github.com/matter-labs/zksync-os-server-private/blob/4d808657cf5156676cb6148f447e66bf154b8a4b/integration-tests/src/upgrade/interfaces.rs#L75-L81
