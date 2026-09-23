# Overview: deposits and withdrawals

L1 → L2 messages enter through Bridgehub and the target chain's mailbox, where they are recorded as
priority operations. ZKsync OS processes those operations in order and commits their results in the
batch output verified by the L1 settlement contracts.

L2 → L1 communication is proof-driven: after a batch is proven and executed, a caller can prove a
message or log against the recorded chain batch root. Deposits, withdrawals, failure recovery, and
cross-chain asset routing build on these two directions.

The current flows are specified in {protocol-docs/bridging.md}, while the root hierarchy and proof
rules are specified in {protocol-docs/message-root.md}.
