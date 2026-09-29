# ZKsync OS chain configuration

## Proof commitment

The batch proof public input commits to the runtime configuration through
`chain_config_hash`. Solidity's `ExecutorFacet` and ZKsync OS's `ChainConfig::hash`
hash the following five 32-byte big-endian words, in order:

1. Chain ID.
2. FRI proof verification enabled (always zero on the settlement layer).
3. Maximum transaction gas limit (the default applies when storage contains zero).
4. Pubdata content (`FULL_PUBDATA = 0`, `LOGS_ONLY = 1`).
5. L1 transaction filtering enabled (`false = 0`, `true = 1`).

The fifth word is included even when filtering is disabled. This changes the hash
from the previous four-word encoding, so the contracts and ZKsync OS runtime must
be upgraded together. The Solidity public-input tests pin the shared golden vector.

## L1 transaction filtering

Filtering is disabled by default, including for chains deployed before the storage
field existed. The chain admin can opt in with `setZKsyncOSL1TxFiltering`; the current
value is exposed by `getZKsyncOSL1TxFiltering`.

When enabled, the operator's transaction validator applies its begin/finish hooks
to priority transactions. A rejected transaction must still be processed and
proven: its body is skipped or rolled back, its full gas limit is charged, the rest
of its deposit is refunded, and its L1 transaction result log reports failure.
Upgrade transactions are never filtered. ZKsync OS records the operator decision
and replays it during proving; committing the flag prevents this discretion from
being used for chains that have not opted in.

### Priority Mode compatibility

L1 transaction filtering cannot coexist with permanently allowed Priority Mode.
The admin must disable filtering before calling `permanentlyAllowPriorityMode`,
and cannot enable it once `canBeActivated` is set, even before Priority Mode is
activated. Setting filtering to disabled remains permitted.

Priority Mode activation depends on the oldest unprocessed priority request
expiring. Filtered transactions still advance the priority queue when their
batches are executed on the settlement layer, so an operator could otherwise
reject recovery calls while keeping that activation condition from being met.

## Configuration updates

The filtering and maximum-transaction-gas setters require the chain admin on the
active settlement layer. Validators and the chain type manager do not have direct
permission to call them unless they are also the chain admin.

All committed batches must be verified before a runtime configuration update.
Proof verification reads the current configuration from storage; changing it while
unverified batches remain would make their proofs inconsistent with the configuration
under which they were executed. Operators must drain the committed batch queue and
coordinate the runtime's configuration with the admin transaction before committing
new batches. A successful filtering update emits `NewZKsyncOSL1TxFiltering` with the
old and new values.

### Pending priority requests

Filtering follows the configuration used to prove a batch, not the configuration
at the time a priority request was admitted on L1. Enabling filtering does not
require an empty priority queue and does not preserve the previous policy for
requests already in that queue. Such requests may be rejected with the full gas
charge described above, even if filtering was disabled when they were submitted.

Changing the flag does not alter already-verified batch results. However, verified
but unexecuted batches may be reverted and their transactions subsequently
recommitted and reproved with filtering enabled. Executed batches cannot be reverted.
