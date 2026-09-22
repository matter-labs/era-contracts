# Data availability

Data availability (DA) is checked as part of batch commitment. The execution environment sends
canonical pubdata through `L1Messenger`; the selected L2 DA validator parses that pubdata and emits an
output commitment. On L1, `ExecutorFacet` calls the chain's configured `IL1DAValidator` with the output
hash and operator input. The returned state-diff hash and publication commitments are included in the
batch commitment verified by the proof system.

## Supported modes

| Mode                        | L1 validation                                                                                                   | Availability assumption                                        |
| --------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Rollup                      | `RollupL1DAValidator` / ZKsync OS blob validator checks calldata and/or blob commitments against the L2 output. | Required state-reconstruction data is published to Ethereum.   |
| Validium                    | `ValidiumL1DAValidator` accepts the committed state-diff hash without requiring the full pubdata on Ethereum.   | Users additionally trust the configured external DA mechanism. |
| Custom DA                   | An `IL1DAValidator` implementation checks a chain-specific attestation or publication proof.                    | Defined by that validator and its external DA layer.           |
| Relayed settlement-layer DA | `RelayedSLDAValidator` binds data relayed through another settlement layer.                                     | Dormant while production chain migrations are disabled.        |

The validator pair is part of the chain's configuration and upgrade boundary. Switching a permanent
rollup to a weaker mode is restricted by the chain administration rules.

## Detailed specifications

- [Architecture overview](./overview.md)
- [State reconstruction](./reconstruction.md)
- [Rollup DA](./rollup_da.md)
- [Validium and zkPorter](./validium_zk_porter.md)
- [Custom DA](./custom_da.md)

The standalone `da-contracts/` package contains reusable L1 validators, including calldata/blob and
Avail-backed implementations. Chain-integrated validators live under
`l1-contracts/contracts/state-transition/data-availability/`.
