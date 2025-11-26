Project: contracts
Scope: L1/L2 state transition (l1l2_state_transition)

## Security issues

### 1. Migration Denial of Service due to Priority Tree Divergence
- **Title**: Chain migration from Gateway back to L1 is impossible if any priority operation occurs on the Gateway.
- **Severity**: High
- **Impact**: Chains that utilize Gateway features (Interop or local deposits) become permanently locked on the Gateway and cannot migrate back to L1. This defeats the purpose of the migration logic and locks user funds/state on the Gateway layer if a return to L1 is required.
- **Description**: 
  The migration logic in `AdminFacet.forwardedBridgeMint` handles the return of a chain from a Settlement Layer (Gateway) to L1. It calls `s.priorityTree.l1Reinit(_commitment.priorityTree)` to synchronize the priority queue state.
  
  In `PriorityTree.l1Reinit`, there is a check:
  ```solidity
  if (_tree.tree._nextLeafIndex < _commitment.nextLeafIndex) {
      revert InvalidNextLeafIndex(_tree.tree._nextLeafIndex, _commitment.nextLeafIndex);
  }
  ```
  This requires that the L1 priority tree has at least as many leaves as the Gateway's priority tree. However, if the chain is active on the Gateway, interactions via `Bridgehub` or `InteropCenter` (which call `MailboxFacet.bridgehubRequestL2TransactionOnGateway`) will push new priority operations to the Gateway's local priority tree, incrementing its `nextLeafIndex`.
  
  Since L1 deposits are paused during migration (`MailboxFacet._writePriorityOp` checks `_depositsPaused` on L1), the L1 tree does not grow. Consequently, `Gateway.nextLeafIndex` becomes greater than `L1.nextLeafIndex`, and `l1Reinit` reverts.
  
  Furthermore, `AdminFacet.forwardedBridgeMint` checks:
  ```solidity
  if (!s.priorityTree.isHistoricalRoot(_commitment.priorityTree.sides[_commitment.priorityTree.sides.length - 1])) {
      revert NotHistoricalRoot(...);
  }
  ```
  Even if indices matched, this requires the Gateway's tree root to be a historical root of the L1 tree. Any divergence in transaction content (e.g., local Gateway transactions) will generate a different root, causing this check to fail.

### 2. Potential Priority Queue Corruption via Unsynchronized Migration
- **Title**: `forwardedBridgeMint` does not sync Priority Tree leaves, leading to data unavailability for execution.
- **Severity**: High
- **Impact**: Even if the indices/roots check in Issue #1 were bypassed or satisfied (e.g. valid L1 relay), `l1Reinit` updates `unprocessedIndex` but does **not** import the actual tree leaves (`_sides`, `_zeros`) from the commitment. If L1 executes batches that reference these "missing" leaves, it may fail or compute incorrect roots.
- **Description**:
  The function `PriorityTree.l1Reinit` only updates `startIndex` and `unprocessedIndex`. It assumes that L1 already possesses all the data (leaves) in its local storage.
  ```solidity
  function l1Reinit(Tree storage _tree, PriorityTreeCommitment memory _commitment) internal {
      // ... checks ...
      _tree.unprocessedIndex = _commitment.unprocessedIndex;
      // No update to _tree.tree data structures
  }
  ```
  If a chain is migrated to Gateway, processes transactions (increasing `unprocessedIndex`), and migrates back, L1 accepts the new `unprocessedIndex`. However, if those processed transactions originated on L1 but were somehow not fully committed to L1's tree state (unlikely if L1 is master), or if the system relies on L1 having the data, this holds. 
  But combined with Issue #1, if *any* data originated on GW, L1 definitely doesn't have it. If the design intent is that L1 *never* imports data and relies solely on its own history, then Issue #1 confirms that **no unique activity can ever happen on Gateway**, rendering Gateway-only features (like cheap interop transactions adding to the queue) incompatible with migration.

### 3. Protocol Version Deadline Can Halt Chain Operations
- **Title**: Malicious or misconfigured CTM protocol deadline causes permanent Denial of Service.
- **Severity**: Medium
- **Impact**: The chain can stop processing new batches entirely if the Chain Type Manager (CTM) sets a protocol version deadline that expires before the chain administrator executes an upgrade.
- **Description**:
  In `ExecutorFacet.commitBatchesSharedBridge`:
  ```solidity
  if (!IChainTypeManager(s.chainTypeManager).protocolVersionIsActive(s.protocolVersion)) {
      revert InvalidProtocolVersion();
  }
  ```
  This checks `block.timestamp <= protocolVersionDeadline`. If the deadline passes, `commitBatches` reverts. While this forces upgrades, it creates a liveness dependency on the CTM's configuration. If the CTM sets a deadline in the past or too soon, the chain halts until the chain admin manually calls `upgradeChainFromVersion`. If the chain admin is slow or the upgrade data is unavailable, the chain remains frozen.