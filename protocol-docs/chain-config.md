# Chain configuration commitments

Starting with protocol v34, every `CommitBatchInfoZKsyncOS` includes `chainConfigHash`.
The committer checks it against the current on-chain runtime configuration before accepting the batch.
The hash is `keccak256(chainId || friProofVerificationEnabled || maxTxGasLimit || pubdataContent)`,
with each value encoded as a 32-byte big-endian word. FRI verification is disabled (zero);
the effective maximum transaction gas limit includes the default for an unset storage value.

The stored batch commitment is the full, untruncated public-input hash:

```
keccak256(previousState || newState || chainConfigHash || batchOutputHash)
```

`StoredBatchInfo.commitment` contains this value; its ABI and storage layout do not change.
Proving authenticates the stored batch hash and passes the commitment directly to the verifier.
It does not read chain configuration. The existing verifier applies public-input truncation after
folding a proof's batch range. Execution authenticates the same stored batch.

## External-node signatures

The external node derives the hash from the configuration used by its own batch execution and
compares the resulting commit data with the operator's request before signing. The existing
MultisigCommitter EIP-712 envelope signs the entire commit payload, including the new hash.
Copying the operator's hash into the signed payload without checking local execution would defeat
this protection. A config change between signing and committing invalidates the stale commit.

## Activation

Commit encoding version 5 appends the config hash; the new decoder rejects earlier commit versions.
The server and external nodes must switch formats at protocol v34. Historical v33 and earlier data
must still be decoded using their original formats.

Before upgrading across the v34 boundary, all committed batches must be proved or reverted.
The v34 upgrade cut must use `ZKsyncOSSettlementLayerV34Upgrade` as its initializer. It checks this
on the active settlement layer before running the generic upgrade, preventing the new executor from
treating legacy batch-output hashes as full public-input hashes. Already-proved batches can remain
unexecuted: execution uses the unchanged stored-batch layout. The inactive chain copy is not gated by
its batch counters.

This precondition belongs only to the v34 upgrade contract. `BaseZkSyncUpgrade` contains no release-specific
batch check, and the v34 contract must not replace the CTM's reusable default upgrade implementation.
Later upgrades select their own initializer and preconditions.

`deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol` prepares this cut and keeps the generic
`DefaultUpgrade` as the CTM default. Select it with `--ctm-script-path` when preparing v34 through
protocol-ops. It uses the default L2 force-deployment payload, without replaying v33 migration work.

Config setters retain their existing guard against updates with unproved committed batches.
The runtime public-input formula and `ChainStateCommitment` are unchanged.
