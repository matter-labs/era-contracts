# Forms of interop finality

The current contracts use two proof forms. The destination determines the proof from the route; users
do not select a finality mode with an SDK flag.

## Atomic IMT finality for L2 -> L2

Every L2 -> L2 bundle is a leg of an atomic flow. The source `InteropCenter` sends the bundle hash to
`AtomicFlowManager`, which inserts a flow-bound commit value into that chain's indexed interop
commitment tree. At batch boundaries the chain batch root commits to the tree root. Settlement then
incorporates the chain batch root into `MessageRoot`, and other L2s import the aggregate root.

`L2InteropHandler.executeAtomicBundle` or `verifyAtomicBundle` receives one inclusion proof per flow
leg. `AtomicFlowManager.requireFlowFinalized` authenticates each source-chain tree root against an
imported interop root and checks that every leg was committed no later than the flow deadline. See
{protocol-docs/atomicity/proofs.md} for the proof format and its soundness argument.

This is commit-based finality in the sense that it proves commitment-tree membership. It is not the
older public-bundle design in which an L2 -> L1 message was proven separately for each L2 -> L2 call.

## Message-inclusion finality for L2 -> L1

An L2 -> L1 bundle is a withdrawal: one indirect, zero-value call produced by the L2 asset router and
targeting the canonical L1 asset router. `InteropCenter` prefixes the ABI-encoded bundle with
`BUNDLE_IDENTIFIER` and publishes it through the L2-to-L1 messenger.

`L1InteropHandler.executeBundle` or `verifyBundle` receives a `MessageInclusionProof`. The handler
reconstructs the prefixed message, requires the canonical L2 `InteropCenter` as its sender, and proves
inclusion through the L1 `MessageRoot`. The L1 handler additionally pins the execution target to the
canonical L1 asset router and rejects non-zero call value.

## Imported-root safety

An imported dependency is a `(chainId, blockOrBatchNumber, root, timestamp)` tuple. The bootloader is
the only writer to `L2InteropRootStorage`; zero roots, zero timestamps, duplicate keys, and malformed
`sides` are rejected. When the importing chain's batch executes, `ExecutorFacet` checks each imported
tuple against `MessageRoot.historicalRoot` on the settlement layer. Protocols such as atomic timeout
may therefore rely on both the root and its timestamp.

## Unsupported historical modes

The ported `zksync-era` documentation also described trigger-based automatic execution,
AliasedAccounts, public non-atomic L2 -> L2 messages, and pre-commit/parallel-building finality. Those
are not supported by this release. `InteropRoot.sides` retains a forward-compatible array encoding,
but current proof- and commit-based imports require exactly one element: the root.
