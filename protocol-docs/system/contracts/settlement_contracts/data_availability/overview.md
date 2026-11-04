# Overview

The DA boundary connects ZKsync OS batch output to `CommitterFacet`. The batch supplies a commitment
and operator publication evidence, and the configured L1 DA validator determines whether that evidence
satisfies the selected availability scheme.

For a rollup, the data required to reconstruct state is published to Ethereum through calldata or
blobs. A validium instead relies on an external availability mechanism, while custom validators can
bind a chain to another DA protocol. These choices do not change proof validity, but they do change
the data-availability assumption users need in order to reconstruct state or exit.

See [rollup DA](./rollup_da.md), [validium](./validium.md), and
[custom DA](./custom_da.md) for the validator-specific flows.
