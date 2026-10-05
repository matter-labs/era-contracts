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

Before upgrading across the v34 boundary, all committed batches must be executed or reverted. This
keeps the new executor from treating legacy batch-output hashes as full public-input hashes.

v34 is a default upgrade: `DefaultCTMUpgrade` prepares it, with no release-specific script or
per-chain initializer. The cut runs the CTM's default `DefaultUpgradeZKsyncOS`, whose all-executed check
enforces the boundary above. The L2 transaction force-deploys `L2DefaultUpgrade` and delegates to it,
with the chain's `ZKChainSpecificForceDeploymentsData` substituted on L1 by
`DefaultUpgradeZKsyncOS.getL2UpgradeTxData`.

Protocol-ops defaults to the default upgrade scripts with a v33-to-v34 local input under
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
