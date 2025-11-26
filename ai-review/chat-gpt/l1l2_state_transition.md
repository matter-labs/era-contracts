## Security issues

### 1. `proveBatchesSharedBridge` is not permissionless despite documentation, making liveness depend solely on validators

- **Severity**: Low  
- **Impact**: If all validator addresses for a chain stop calling `proveBatchesSharedBridge` (maliciously or due to failure), new batches can no longer be proven or executed, effectively halting the chain and blocking withdrawals and message processing until governance intervenes (e.g., by rotating validators). This is a liveness—not safety—issue, but it is at odds with the comment suggesting this entrypoint should be permissionless.

**Details**

In `ExecutorFacet`:

```solidity
/// @inheritdoc IExecutor
// Warning: removed onlyValidator to make it permisionless.
function proveBatchesSharedBridge(
    address, // _chainAddress
    uint256 _processBatchFrom,
    uint256 _processBatchTo,
    bytes calldata _proofData
) external nonReentrant onlyValidator onlySettlementLayer {
    (
        StoredBatchInfo memory prevBatch,
        StoredBatchInfo[] memory committedBatches,
        uint256[] memory proof
    ) = BatchDecoder.decodeAndCheckProofData(_proofData, _processBatchFrom, _processBatchTo);
    ...
    _verifyProof(proofPublicInput, proof);
    ...
    s.totalBatchesVerified = currentTotalBatchesVerified;
}
```

Despite the comment “removed onlyValidator to make it permisionless”, the function is still guarded by:

```solidity
modifier onlyValidator() {
    if (!s.validators[msg.sender]) {
        revert Unauthorized(msg.sender);
    }
    _;
}
```

and by `onlySettlementLayer` (which enforces `s.settlementLayer == address(0)`).

Execution of batches is gated on proof availability:

```solidity
function executeBatchesSharedBridge(...) external nonReentrant onlyValidator onlySettlementLayer {
    ...
    uint256 newTotalBatchesExecuted = s.totalBatchesExecuted + nBatches;
    s.totalBatchesExecuted = newTotalBatchesExecuted;
    if (newTotalBatchesExecuted > s.totalBatchesVerified) {
        revert CantExecuteUnprovenBatches();
    }
    ...
}
```

So if validators refuse to prove, the chain cannot execute further batches and effectively stalls.

**Why this matters**

The code comment suggests that proof submission was intended to be permissionless (e.g., “anyone can pay to prove a batch”), which would remove liveness dependence on the current validator set. As implemented, liveness of the proving step is entirely dependent on addresses in `s.validators`, controlled via `AdminFacet.setValidator` (CTM only).

There is no direct *safety* breach (no unauthorized finalization or state corruption), but:

- Users and integrators reading the comment may assume they can submit proofs permissionlessly while they actually cannot.
- A malicious or failed validator set can indefinitely block progress until CTM governance rotates validators (an off‑chain, social/manual process).

**Recommendation**

- Either:
  - Make `proveBatchesSharedBridge` truly permissionless by removing `onlyValidator`, or  
  - Update the comment and external documentation to make clear that only validators can prove batches and that liveness depends on them.
- If permissionless proving is desired longer-term, consider:
  - Introducing a separate permissionless “verify proof” entrypoint that only accepts proofs for already-committed batch ranges and still uses the same verifier, while keeping validator-only paths for commit/execute.


---

## Open issues / areas needing broader context

The following items looked potentially risky but could not be fully validated within the provided scope. They likely rely on guarantees from other components (Bridgehub, chain asset handler, L1/L2 Bridgehubs, AssetRouter, MessageRoot, etc.):

1. **Trust in `_baseTokenAmount` on Gateway path (safe by design)**  
   - In `MailboxFacet.requestL2TransactionToGatewayMailboxWithBalanceChange`, the Gateway-side Mailbox trusts the calling chain to provide `_baseTokenAmount`:
     ```solidity
     // Note, that here we trust the calling chain to provide the correct _baseTokenAmount.
     // This means that only CTMs that ZK Gateways can trust can exist in this release.
     balanceChange.baseTokenAmount = _baseTokenAmount;
     ```
   - Misreporting this value by a malicious or buggy chain could, in isolation, break accounting of base-token movement between L1, Gateway, and hyperchains.  
   - The docs explicitly acknowledge and constrain this (“only CTMs that ZK Gateways can trust”), so this is **safe by design**, but it means correctness and solvency depend on the integrity of whitelisted CTMs and Bridgehub’s whitelisting logic.
   - To fully analyze risk here, the following sources would be needed:
     - `Bridgehub` and `chainAssetHandler` implementations
     - `IL1AssetTracker` / `INativeTokenVaultBase` and their invariants

2. **Correctness of the L1↔Gateway deposit flow and `onlyL1`/`onlyGateway` gating**  
   - `MailboxFacet` has several functions restricted with `onlyL1` or `onlyGateway`. For example:
     ```solidity
     function requestL2TransactionToGatewayMailboxWithBalanceChange(...) public override onlyL1 returns (...)
     ```
   - At first glance, there is some complexity in how L1 representations of chains and Gateway settlement-layer instances interact, especially during/after migration, and how these modifiers are enforced across those roles.
   - From the contracts and docs given, the design appears internally consistent, but validating that no deposit path is accidentally blocked or misrouted requires looking at:
     - Full `Bridgehub` logic and how it chooses which chain instance (L1 vs Gateway) to call for a given chainId.
     - The chain migration flows implemented in Bridgehub / chain asset handler.
   - Without those components, we can’t categorically rule out configuration or routing mistakes, but nothing in the provided code alone demonstrates a concrete bug.