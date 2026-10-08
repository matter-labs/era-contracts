# Per-chain settlement contract

Each chain has an L1 diamond proxy whose facets share `ZKChainStorage`:

| Facet            | Responsibility                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `CommitterFacet` | Precommit and commit batches, validate the batch encoding and timestamps, call the configured L1 DA validator, and store commitments.      |
| `ExecutorFacet`  | Verify proofs, execute proven batches, consume priority-tree entries, store L2 -> L1 roots, and update message-root state.                 |
| `MailboxFacet`   | Accept L1 -> L2 priority operations, quote base cost, and expose transaction and priority-tree state.                                      |
| `AdminFacet`     | Apply CTM-approved upgrades and manage chain-local fee, DA, Priority Mode, pause/freeze, and transaction-filter settings.                  |
| `GettersFacet`   | Expose chain state and EIP-2535 diamond-loupe views without mutating storage.                                                              |
| `MigratorFacet`  | Hold deposit-pause and migration-compatibility entry points; production chain migration is disabled by the current release-level constant. |

The proxy fallback dispatches selectors to facets. Freezing the diamond blocks facets marked freezable;
getter and recovery paths that must remain available are configured accordingly.

## Batch lifecycle

1. **Commit:** `CommitterFacet` decodes the ZKsync OS batch encoding, checks ordering and timestamps,
   invokes the configured L1 DA validator, and stores the batch commitment.
2. **Prove:** verify one or more committed batches with the verifier registered for the chain's active
   protocol version.
3. **Execute:** `ExecutorFacet` finalizes proven batches in order, consumes the matching priority-tree
   segment, stores the resulting L2 -> L1 root, and updates the message root.

The committer rejects operator input that does not match the ZKsync OS batch encoding selected by the
chain configuration.

## Priority operations and messages

L1 -> L2 requests are hashed into a priority structure and must be processed by L2 in order. The
current protocol uses the priority tree, with a legacy queue compatibility path only for operations
created before tree activation. L2 -> L1 logs
and messages become actionable only after their batch is executed and a caller supplies the appropriate
Merkle proof. See [priority operations](./priority_queue/README.md) and {protocol-docs/message-root.md}.

## Data availability

The committed ZKsync OS batch carries a DA commitment. `CommitterFacet` invokes the chain's configured
L1 DA validator with that commitment and the operator input. The ZKsync OS blob validator checks the
published blob-versioned hashes and returns empty legacy state-diff/blob-opening outputs. See
[data availability](./data_availability/README.md).
