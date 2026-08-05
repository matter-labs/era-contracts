# Protocol docs

The protocol — flows, motivations, security arguments, design trade-offs — is described here, once.
Code comments stay minimal and reference these files as `{protocol-docs/<name>.md}` instead of
restating them (see the "Documentation and Comments" section of `AGENTS.md`).

| Document                                       | Covers                                                                                                                                                                              |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [interop.md](./interop.md)                     | Interop bundles and calls, ERC-7786/ERC-7930 usage, attributes, fee model, send flow, destination-side execution/unbundling, interop-root import, restrictions                      |
| [atomicity/](./atomicity/README.md)            | Atomic multi-leg interop flows (folder): the commitment tree, the send/finalize/timeout lifecycle, the finality & timeout proofs, refund/recovery semantics, and the security model |
| [bridging.md](./bridging.md)                   | Asset router, native token vault, L2 asset tracker, L1 nullifier, base-token handling, failed-transfer recovery, legacy compatibility                                               |
| [message-root.md](./message-root.md)           | Message-root aggregation, chain batch root tree, batch-leaf timestamps, the Indexed Merkle Tree, interop-root import double-check, proof paths                                      |
| [chain-lifecycle.md](./chain-lifecycle.md)     | Chain creation and genesis seeding, interop registration gating, the v32 chain-migrations ban, ZKsync OS genesis force deployments                                                  |
| [l1-interop-center.md](./l1-interop-center.md) | The ERC-7786 entry point for L1→L2 requests that relays to the Bridgehub: message shape, attributes, sender semantics, indirect-call limits                                         |

The `atomicity/` folder is split into a layered set of pages (start at its README):

- [atomicity/README.md](./atomicity/README.md) — overview, key values, lifecycle tour, contracts, genesis, tooling
- [atomicity/imt.md](./atomicity/imt.md) — the per-chain interop commitment tree
- [atomicity/flow.md](./atomicity/flow.md) — the send/finalize/timeout lifecycle and the `AtomicFlowManager`
- [atomicity/proofs.md](./atomicity/proofs.md) — the finality & timeout proof system (soundness/completeness)
- [atomicity/recovery.md](./atomicity/recovery.md) — the timeout/refund path and recovery semantics
- [atomicity/security.md](./atomicity/security.md) — guarantees, non-guarantees, preconditions, trust assumptions

There are no protocol-narrative READMEs inside the contract source trees: every `.sol`/`.ts`/`.rs`
file points here with `{protocol-docs/...}` instead of carrying its own prose.
