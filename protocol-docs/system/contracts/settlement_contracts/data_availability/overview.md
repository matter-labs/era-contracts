# Overview

The DA boundary connects ZKsync OS batch output to the L1 executor. The L2 DA validator commits to
the state-diff data and publication inputs produced for a batch. The configured L1 DA validator then
checks the operator-supplied publication evidence and returns the values included in the L1 batch
commitment.

For a rollup, the data required to reconstruct state is published to Ethereum through calldata or
blobs. A validium instead relies on an external availability mechanism, while custom validators can
bind a chain to another DA protocol. These choices do not change proof validity, but they do change
the data-availability assumption users need in order to reconstruct state or exit.

See [rollup DA](./rollup_da.md), [validium and zkPorter](./validium_zk_porter.md), and
[custom DA](./custom_da.md) for the validator-specific flows.
