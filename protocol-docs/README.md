# Protocol docs

The protocol — flows, motivations, security arguments, design trade-offs — is described here, once.
Code comments stay minimal and reference these files as `{protocol-docs/<name>.md}` instead of
restating them (see the "Documentation and Comments" section of `AGENTS.md`).

| Document                                   | Covers                                                                                                                                                                              |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [interop.md](./interop.md)                 | Interop bundles and calls, ERC-7786/ERC-7930 usage, attributes, fee model, send flow, destination-side execution/unbundling, interop-root import, restrictions                      |
| [atomicity/](./atomicity/README.md)        | Atomic multi-leg interop flows (folder): the commitment tree, the send/finalize/timeout lifecycle, the finality & timeout proofs, refund/recovery semantics, and the security model |
| [bridging.md](./bridging.md)               | Asset router, native token vault, L2 asset tracker, L1 nullifier, base-token handling, failed-transfer recovery, legacy compatibility                                               |
| [message-root.md](./message-root.md)       | Message-root aggregation, chain batch root tree, batch-leaf timestamps, the Indexed Merkle Tree, interop-root import double-check, proof paths                                      |
| [chain-lifecycle.md](./chain-lifecycle.md) | Chain creation and genesis seeding, interop registration gating, the v32 chain-migrations ban, ZKsync OS genesis force deployments                                                  |
