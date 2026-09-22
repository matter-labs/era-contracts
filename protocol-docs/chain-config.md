# ZKsync OS chain configuration

## Proof commitment

The batch proof public input commits to the runtime configuration through
`chain_config_hash`. Solidity's `ExecutorFacet` and ZKsync OS's `ChainConfig::hash`
hash the following six 32-byte big-endian words, in order:

1. Chain ID.
2. FRI proof verification enabled (always zero on the settlement layer).
3. Maximum transaction gas limit (the default applies when storage contains zero).
4. Pubdata content (`FULL_PUBDATA = 0`, `LOGS_ONLY = 1`).
5. L1 transaction filtering enabled (`false = 0`, `true = 1`).
6. Large contracts enabled (`false = 0`, `true = 1`).

Both boolean words are included even when disabled. The sixth word changes the
hash from the previous five-word encoding, so the contracts and ZKsync OS runtime
must be upgraded together with this field order. The Solidity public-input tests
pin the default golden vector; batch-proving tests cover all four combinations of
these flags.

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

## Large contracts

Large contracts are disabled by default, including for existing chains. The chain
admin can opt in with `setZKsyncOSLargeContracts`; the current value is exposed by
`getZKsyncOSLargeContracts`. `AdminFunctions.setZKsyncOSLargeContracts` prepares or
sends the corresponding admin call.

| Enabled | Maximum deployed code | Maximum initcode |
| ------- | --------------------- | ---------------- |
| `false` | 24 KiB                | 48 KiB           |
| `true`  | 64 KiB                | 128 KiB          |

The runtime enforces these limits. Gas pricing and resource budgets are unchanged.
Disabling the option restricts subsequent deployments; already deployed large
contracts remain callable. Updates emit `NewZKsyncOSLargeContracts` with the old
and new values.

## Configuration updates

The filtering, large-contracts, and maximum-transaction-gas setters require the chain admin on the
active settlement layer. Validators and the chain type manager do not have direct
permission to call them unless they are also the chain admin.

All committed batches must be verified before a runtime configuration update.
Proof verification reads the current configuration from storage; changing it while
unverified batches remain would make their proofs inconsistent with the configuration
under which they were executed. Operators must drain the committed batch queue and
coordinate the runtime's configuration with the admin transaction before committing
new batches. A successful filtering update emits `NewZKsyncOSL1TxFiltering` with the
old and new values.
