# Atomic multi-leg flow

Consider an exchange where one participant transfers an asset from chain A to chain B while another
transfers a different asset from chain C to chain A. Each source creates its own bundle, but every
bundle belongs to one `AtomicFlowPreimage`:

- `legBundleHashes` contains all previewed bundle hashes in strictly ascending order;
- `legSourceChainIds` contains the corresponding source chain for each hash;
- `deadline` is the latest L1 settlement timestamp at which every commitment may enter its source
  chain's settled tree;
- `settlementLayerChainId` is the L1 chain ID in this release.

Each participant obtains its bundle hash from `previewBundleHash`, computes the same preimage and
`flowId`, obtains the insertion's `lowNullifierIndex`, and sends its real bundle with the
`atomicBundle` attribute. `AtomicFlowManager.append` checks that the sent bundle hash is one of the
declared legs, that its declared source is the current chain, that every source chain is registered,
and that the deadline has not already passed.

No destination can execute after only a subset of legs commits. Each
`executeAtomicBundle(bundle, finalityProof)` proves inclusion for every declared leg and authenticates
the corresponding commitment-tree roots through the imported interop root. Once that proof succeeds,
destinations may be driven independently.

If any leg is absent after the deadline, an absence proof for that one leg authorizes recovery for all
committed legs of the flow on each source chain. Finality and timeout proofs are mutually exclusive,
so the same flow cannot become executable and refundable.

This guarantee is about permission, not synchronous execution: a finalized bundle may remain
unexecuted if nobody submits it, and a verified multi-call bundle may be partially executed or have
individual calls cancelled through unbundling. Applications requiring all destination-side effects to
happen must add their own liveness/incentive mechanism and account for the protocol's best-effort
recovery limits. See {protocol-docs/atomicity/security.md#guarantees}.
