# Per-chain settlement contract

Each chain has an L1 diamond proxy whose facets share `ZKChainStorage`:

| Facet           | Responsibility                                                                                                                      |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `ExecutorFacet` | Commit batches, verify proofs, execute finalized batches, validate DA output, and update batch/message-root state.                  |
| `MailboxFacet`  | Accept L1 -> L2 priority operations, quote base cost, prove L2 -> L1 messages/logs, and expose settlement-layer relay entry points. |
| `AdminFacet`    | Apply CTM-approved upgrades and manage the limited validator, fee, DA, pause/freeze, and transaction-filter settings.               |
| `GettersFacet`  | Expose chain state and EIP-2535 diamond-loupe views without mutating storage.                                                       |

The proxy fallback dispatches selectors to facets. Freezing the diamond blocks facets marked freezable;
getter and recovery paths that must remain available are configured accordingly.

## Batch lifecycle

1. **Commit:** decode the batch encoding for the chain's execution environment, check ordering and
   timestamps, validate required system logs and DA output, and store the batch commitment.
2. **Prove:** verify one or more committed batches with the verifier registered for the chain's active
   protocol version.
3. **Execute:** finalize proven batches in order, consume the matching priority operations, store the
   resulting L2 -> L1 root, and update the settlement-layer message root.

EraVM and ZKsync OS use different batch encodings and chain-batch-root construction, selected by the
chain configuration. The shared executor rejects an encoding that does not match the configured VM.

## Priority operations and messages

L1 -> L2 requests are hashed into a priority structure and must be processed by L2 in order. The
current protocol supports the legacy queue where required and the newer priority tree. L2 -> L1 logs
and messages become actionable only after their batch is executed and a caller supplies the appropriate
Merkle proof. See [priority operations](./priority_queue/README.md) and {protocol-docs/message-root.md}.

## Data availability

The committed batch names the L2 DA validator and its output hash. `ExecutorFacet` invokes the chain's
configured L1 DA validator with the operator input and binds the returned state-diff hash, blob hashes,
and opening commitments into the batch commitment. See [data availability](./data_availability/README.md).
