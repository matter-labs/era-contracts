# Documentation

Everything written about these contracts lives in this folder: the protocol specification, the developer guides, and
the operational guides for deploying and upgrading an ecosystem.

## Protocol

The protocol — flows, motivations, security arguments, design trade-offs — is described here, once.

| Document                                                     | Covers                                                                                                                                                                                                                                             |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [system/](./system/README.md)                                | Complete contracts architecture: system map, trust boundaries, Bridgehub and chain management, settlement, DA, bridges, consensus, and execution environments                                                                                      |
| [interop/](./interop/README.md)                              | Cross-chain interop: the interop protocol (bundles, calls, ERC-7786 attributes, fees, handlers, root import), contract architecture, finality forms, atomic multi-leg flows (commitment tree, lifecycle, proofs, recovery, security), and examples |
| [bridging.md](./bridging.md)                                 | Asset router, native token vault, L2 asset tracker, L1 nullifier, base-token handling, failed-transfer recovery, legacy compatibility                                                                                                              |
| [message-root.md](./message-root.md)                         | Message-root aggregation, chain batch root tree, batch-leaf timestamps, the Indexed Merkle Tree, interop-root import double-check, proof paths                                                                                                     |
| [chain-lifecycle.md](./chain-lifecycle.md)                   | Chain creation and genesis seeding, interop registration gating, the current chain-migrations ban, ZKsync OS genesis force deployments                                                                                                             |
| [chain-config.md](./chain-config.md)                         | Commit-time configuration binding, external-node signatures, L1 transaction filtering, large contracts, v34 activation, and upgrade tooling                                                                                                        |
| [upgrade-scheduling.md](./upgrade-scheduling.md)             | `ServerNotifier` scheduling, optional per-version precondition checkers, registration and execution-time guarantees                                                                                                                                |
| [l1-transaction-gas-limit.md](./l1-transaction-gas-limit.md) | Priority-transaction gas ceiling, chain limits, upgrade behavior, and queued-transaction compatibility                                                                                                                                             |
| [multi-proof-verification.md](./multi-proof-verification.md) | Multi-proof verification with a ZiSK second prover: proof modes, the per-chain switch, rollout                                                                                                                                                     |

Start with [the system architecture](./system/README.md) when reading the protocol as a whole. The other documents are
the normative descriptions of individual flows and are linked from that map.

The `atomicity/` folder is split into a layered set of pages (start at its README):

- [atomicity/README.md](./atomicity/README.md) — overview, key values, lifecycle tour, contracts, genesis, tooling
- [atomicity/imt.md](./atomicity/imt.md) — the per-chain interop commitment tree
- [atomicity/flow.md](./atomicity/flow.md) — the send/finalize/timeout lifecycle and the `AtomicFlowManager`
- [atomicity/proofs.md](./atomicity/proofs.md) — the finality & timeout proof system (soundness/completeness)
- [atomicity/recovery.md](./atomicity/recovery.md) — the timeout/refund path and recovery semantics
- [atomicity/security.md](./atomicity/security.md) — guarantees, non-guarantees, preconditions, trust assumptions

There are no protocol-narrative READMEs inside the contract source trees: every `.sol`/`.ts`/`.rs` file points here
instead of carrying its own prose.

## Developer guides

| Document                                      | Covers                                                                                                     |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [atomic-interop/](./atomic-interop/README.md) | Building on atomic interop (v33): overview, flows, a tutorial on two local chains, reference, and the demo |

## Operations

| Document                                                     | Covers                                                                                                                                                                                 |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [ecosystem-deployment.md](./ecosystem-deployment.md)         | Deploying a fresh ecosystem: the hub, CTM and chain layers, what each script deploys and wires, the inputs, ownership after deployment, verification, the tooling (`protocol_ops`, CI) |
| [ecosystem-upgrade.md](./ecosystem-upgrade.md)               | Upgrading an ecosystem to a new release: artifacts, the prepare / deploy / verify / governance / per-chain pipeline, who signs what, authoring a release's scripts                     |
| [ecosystem-upgrade-deploy.md](./ecosystem-upgrade-deploy.md) | The v31 ecosystem upgrade's runbook: generating the calldata, deploying it and verifying the deployment, locally and in CI                                                             |
| [release-tags.md](./release-tags.md)                         | How release tags are named and created, and the daily check that every live CTM version is tagged                                                                                      |

## Internal

[ai-review/](./ai-review/README.md) holds the team's AI code-review prompts and the shared review notes they read.

## Pointers from code

Code comments stay minimal and reference these files as `{docs/<name>.md}` instead of restating them (see the
"Documentation and Comments" section of `AGENTS.md`). Contract sources write the same pointer as
`{protocol-docs/<name>.md}`, from when the protocol docs had their own folder; both forms resolve to this folder, and
`yarn docs-anchor-lint` checks that every pointer does.
