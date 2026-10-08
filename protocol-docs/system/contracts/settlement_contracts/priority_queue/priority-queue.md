# Priority tree

The current settlement contracts store L1 → L2 priority-operation hashes in the append-only
`PriorityTree`. The previous linear queue remains only as deprecated storage needed while operations
created before the tree's activation are drained.

## State

The tree records:

- `startIndex`: the global priority-operation index at which the tree became active;
- `unprocessedIndex`: the next unprocessed leaf relative to `startIndex`;
- `_nextLeafIndex` and the incremental Merkle frontier (`sides`);
- every root produced by an append in `historicalRoots`.

`getFirstUnprocessedPriorityTx`, `getTotalPriorityTxs`, and `getSize` combine these indices to expose
the global queue position while the tree itself uses relative leaf indices.

## Appending operations

`MailboxFacet` validates and hashes each canonical L1 → L2 transaction, then calls
`s.priorityTree.push(canonicalTxHash)`. `push` appends the hash to the dynamic incremental Merkle tree
and records the resulting root as historical. The mailbox also records the request timestamp under
the new operation's global index for Priority Mode activation.

## Processing a batch

Execution calldata supplies `PriorityOpsBatchInfo`:

```solidity
struct PriorityOpsBatchInfo {
  bytes32[] leftPath;
  bytes32[] rightPath;
  bytes32[] itemHashes;
}
```

`ExecutorFacet` first requires `itemHashes.length` to equal the committed number of L1 transactions
and recomputes their rolling hash. `PriorityTree.processBatch` then reconstructs the Merkle root for
that contiguous segment starting at `unprocessedIndex`. The reconstructed root must be one of the
recorded historical roots; if it is valid, `unprocessedIndex` advances by the number of leaves.

Historical roots let a proof remain valid when additional priority operations are appended after the
operator constructs the batch proof. Ordering follows from the segment's fixed start index, and the
batch commitment binds the supplied item hashes through their rolling hash.

## Legacy transition

`ZKChainStorage.__DEPRECATED_priorityQueue` is not the current insertion path. `ZKChainBase` checks
whether old queue entries remain below `priorityTree.startIndex` and processes that prefix through the
legacy compatibility path. New requests are appended only to `PriorityTree`.
