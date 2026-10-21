# ZKsync OS chain configuration

## Proof commitment

Starting with protocol v34, every `CommitBatchInfoZKsyncOS` includes `chainConfigHash`.
The committer checks it against the current on-chain runtime configuration before accepting the batch.

The batch proof public input commits to the runtime configuration through
`chain_config_hash`. Solidity's `ZKChainBase._getZKsyncOSChainConfigHash()` and ZKsync OS's `ChainConfig::hash`
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
pin the shared default and flag-combination vectors from ZKsync OS's
[`public_input.rs`](https://github.com/matter-labs/zksync-os-private/blob/ca730149b70ceb296dd2c4158823e152c90ae92b/basic_bootloader/src/bootloader/block_flow/zk/post_tx_op/public_input.rs).
The vectors with exactly one flag enabled detect swaps of the boolean words.
Batch-proving tests explicitly cover all four combinations.

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

Before upgrading across the v34 boundary, all committed batches must be executed or reverted. This
keeps the new executor from treating legacy batch-output hashes as full public-input hashes.

v34 is prepared by `CTMUpgrade_v34`, the default CTM upgrade with one change: the cut runs
`V34UpgradeZKsyncOS`, which adds the priority gas-limit clamp described in
{protocol-docs/l1-transaction-gas-limit.md} to `DefaultUpgradeZKsyncOS`. The CTM default stays
`DefaultUpgradeZKsyncOS`. Its all-executed check enforces the boundary above. The L2 transaction
force-deploys `L2DefaultUpgrade` and delegates to it, with the chain's
`ZKChainSpecificForceDeploymentsData` substituted on L1 by `DefaultUpgradeZKsyncOS.getL2UpgradeTxData`.

Protocol-ops defaults to `DefaultCoreUpgrade` and `CTMUpgrade_v34`, with a v33-to-v34 local input under
`upgrade-envs/v0.34.0-chain-config/local.toml`. The visible `--ctm-script-path`,
`--core-script-path`, and `--upgrade-input-path` flags select historical or environment-specific
preparations. A named environment must supply its v34 input; missing inputs fail rather than falling
back to v33 or local parameters. The anvil upgrade test runs exactly these defaults against the v33 chain
states, so it covers v33 to v34.

Config setters retain their existing guard against updates with unproved committed batches to keep
this commitment-format upgrade from also changing the existing administrative update policy. This
guard is no longer required for provability: each committed batch retains its own configuration hash.
Relaxing the update policy is a separate protocol decision.

`getZKsyncOSChainConfigHash()` exposes the hash on the queried chain copy. Tooling should query the
active settlement-layer copy, at the relevant block when checking a historical commit. This getter
helps cross-check the encoding; external nodes still derive the hash from their own execution config.

The runtime public-input formula and the ZKsync OS runtime's
[`ChainStateCommitment`](https://github.com/matter-labs/zksync-os-private/blob/draft-0.6.0/basic_bootloader/src/bootloader/block_flow/zk/post_tx_op/public_input.rs)
are unchanged.

## Transition regression

The v34 diamond-transition test deploys frozen pre-v34 Committer and Executor bytecode from
`7b398269a03e531fefa013d14a16f15c5fdfd16c`. It commits version-4 data, proves the legacy batch,
executes it, applies the script-generated v34 cut, and commits/proves/executes version-5 data. Two
more paths check that an unverified or a proved-but-unexecuted legacy batch prevents the cut and
leaves both facets and stored batch data intact.

The fixture records its source revision and compiler/toolchain settings. Regenerate it only when
intentionally changing the historical baseline: export that revision, build the two facets with the
pinned upstream Foundry toolchain, and copy their `bytecode.object` fields into the fixture. These
historical bytes are not part of the current-contract artifact regeneration.

## L1 transaction filtering

Filtering is disabled by default, including for chains deployed before the storage
field existed. The chain admin can opt in with `setZKsyncOSL1TxFiltering`; the current
value is exposed by `isZKsyncOSL1TxFilteringEnabled`.

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

## Large contracts

Large contracts are disabled by default, including for existing chains. The chain
admin can opt in with `setZKsyncOSLargeContractsEnabled`; the current value is
exposed by `isZKsyncOSLargeContractsEnabled`.
`AdminFunctions.setZKsyncOSLargeContractsEnabled` prepares or sends the
corresponding admin call.

| Enabled | Maximum deployed code | Maximum initcode |
| ------- | --------------------- | ---------------- |
| `false` | 24 KiB                | 48 KiB           |
| `true`  | 64 KiB                | 128 KiB          |

The runtime enforces these limits; its
[`ChainConfig`](https://github.com/matter-labs/zksync-os-private/blob/ca730149b70ceb296dd2c4158823e152c90ae92b/zk_ee/src/system/metadata/chain_config.rs)
defines both sizes. See the runtime's
[code-size documentation](https://github.com/matter-labs/zksync-os-private/blob/ca730149b70ceb296dd2c4158823e152c90ae92b/docs/system/large_contracts.md)
for the unchanged gas pricing and resource budgets. Disabling the option restricts
subsequent deployments; already deployed large contracts remain callable.

## Configuration updates

The filtering, large-contracts, and maximum-transaction-gas setters require the
chain admin on the active settlement layer. Validators and the chain type manager
do not have direct permission to call them unless they are also the chain admin.

All committed batches must be verified before a runtime configuration update.
This existing admin guard is retained even though proof verification now uses the stored
batch commitment. Operators must drain the committed batch queue and
coordinate the runtime's configuration with the admin transaction before committing
new batches. Successful updates emit `NewZKsyncOSL1TxFiltering`,
`NewZKsyncOSLargeContracts`, or `NewZKsyncOSMaxTxGasLimit`, respectively, with the
old and new values.

### Pending priority requests

Filtering follows the configuration used to execute and commit a batch, not the configuration
at the time a priority request was admitted on L1. Enabling filtering does not
require an empty priority queue and does not preserve the previous policy for
requests already in that queue. Such requests may be rejected with the full gas
charge described above, even if filtering was disabled when they were submitted.

Changing the flag does not alter already-verified batch results. However, verified
but unexecuted batches may be reverted and their transactions subsequently
recommitted and reproved with filtering enabled. Executed batches cannot be reverted.
