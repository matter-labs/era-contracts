# Custom data-availability validators

A chain configures an L1 validator and a commitment-scheme identifier as a pair through
`AdminFacet.setDAValidatorPair`. The validator address must be non-zero, the scheme cannot be `NONE`,
and `BLOBS_ZKSYNC_OS` can be selected only for a ZKsync OS chain.

At batch commitment, `CommitterFacet` requires the scheme carried by `CommitBatchInfoZKsyncOS` to
match the configured scheme, then calls:

```solidity
IL1DAValidator.checkDA(
  chainId,
  batchNumber,
  daCommitment,
  operatorDAInput,
  maxBlobsSupported
)
```

The meaning of `daCommitment` and `operatorDAInput` is defined by the selected validator. This makes
the validator a data-availability trust boundary: the proof authenticates the committed value, while
the validator determines what evidence is sufficient to consider the underlying data available.

For permanent rollups, `RollupDAManager` must approve the exact validator/scheme pair before it can be
selected. Once `makePermanentRollup` succeeds, the chain must retain an approved rollup pair and full
pubdata mode.
