# ZKIP proof-carried accounting experiment

This design applies only to `zkip-poc/`, stacked on the direct and aggregation research PoCs. It does not
change production protocol contracts or settlement semantics.

## Complete outgoing debits

The original debit circuit checked caller-supplied commit values; the L1 registry separately verified
their indexed-Merkle insertions. The revised debit circuit proves the complete insertion sequence from
the batch's IMT begin root to its end root and debits every inserted leg. Transfer preimages and insertion
paths are private witnesses, not L1 calldata.

The proof checks the predecessor's membership and 256-bit ordering, preserves its successor, updates the
predecessor link, verifies that the append slot is empty, handles tree-height growth, and checks the final
root. An omitted leg cannot reach the committed end root. Duplicate inserts fail the strict ordering
checks. The existing depth-16 bound is enforced as an explicit capacity limit.

The registry authenticates the batch-root preimage against the chain's committed batch, enforces continuity
with its previously proven IMT root, and supplies the stored starting leaf count as a public input. It
verifies the proof before updating the private-state commitment, proven IMT root/count, execution gate,
or public cap. No per-leg insertion hash is calculated by the registry.

Both debit size classes have sixteen public inputs: chain ID, L1 ID, previous/new state roots, leg count,
begin-root halves, end-root halves, starting leaf count, lock-asset halves, lock amount, and three zero
reserved fields. Normalizing the vector allows the aggregator to accept the one-leg circuit instead of
forcing single transfers through the four-leg circuit. Verification-key commitments remain explicitly
approved on L1.

## Hash and encoding experiments

The running PoC keeps existing Keccak bundles and trees so that insertion proofs can be tested against
the actual protocol's indexed-Merkle implementation. Separate benchmark variants use compact typed
transfers and alternative commitment hashes. Their formats, measurements, and trust boundaries are in
[`zkip-poc/benchmarks/README.md`](../zkip-poc/benchmarks/README.md).

Changing source IMT hashes requires a source-chain change. Changing the chain/shared settlement trees
also requires a settlement change: today those roots are updated using Keccak on L1. Merely substituting
the Noir hash would authenticate a different root. A future proof-maintained settlement accumulator must
bind accepted batches, chain identities, and L1-authenticated timestamps before an alternative finality
root can replace the current hierarchy.
