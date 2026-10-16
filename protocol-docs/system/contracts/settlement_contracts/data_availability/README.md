# Data availability

Data availability (DA) is checked by `CommitterFacet` as part of ZKsync OS batch commitment.
`CommitBatchInfoZKsyncOS` carries the configured commitment scheme, the ZKsync OS DA commitment, and
operator input. The committer requires the scheme to match chain storage and calls the configured
`IL1DAValidator` with the commitment and publication evidence.

## Supported modes

| Mode            | L1 validation                                                                                                     | Availability assumption                                        |
| --------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| ZKsync OS blobs | `BlobsL1DAValidatorZKsyncOS` checks that published blob-versioned hashes match the ZKsync OS DA commitment.       | Required state-reconstruction data is published to Ethereum.   |
| Validium        | `ValidiumL1DAValidator` accepts operator input without requiring the reconstruction data on Ethereum.             | Users additionally trust the configured external DA mechanism. |
| Custom DA       | Another `IL1DAValidator` implementation interprets the commitment and checks chain-specific publication evidence. | Defined by that validator and its external DA layer.           |

The validator pair is part of the chain's configuration and upgrade boundary. Switching a permanent
rollup to a weaker mode is restricted by the chain administration rules.

## Detailed specifications

- [Architecture overview](./overview.md)
- [State reconstruction](./reconstruction.md)
- [Rollup DA](./rollup_da.md)
- [Validium](./validium.md)
- [Custom DA](./custom_da.md)

The standalone `da-contracts/` package contains reusable L1 validators, including calldata/blob and
Avail-backed implementations. Chain-integrated validators live under
`l1-contracts/contracts/state-transition/data-availability/`.
