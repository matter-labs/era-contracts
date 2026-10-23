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

## Compact aggregated settlement

The outer proof recursively verifies the same four inner proofs, but exposes eight fields rather than
the previous 68. For each slot it exposes the high and low 128-bit halves of
`keccak256(domain || vkCommitment || innerPublicInputs)`. The domain is
`keccak256("zkSync:ZKIP:aggregatedStatement:v1")`; every concatenated element is a 32-byte big-endian word,
and the input vector has exactly sixteen elements. The VK commitment remains Poseidon2 over the
recursively verified key. The 256-bit statement digest is split rather than reduced modulo the circuit field.

L1 receives the four VK commitments and the debit/claim submissions. It verifies the outer proof,
checks that the selected VK is approved, reconstructs the sixteen inputs from current authenticated
state, and compares their digest before applying a slot. A changed amount, root, chain identity or
substituted approved key cannot match the proven digest. Stale slots are still skipped independently;
later slots see the state produced by earlier successful slots. Unused slots repeat a real proof.
Submission arrays must contain exactly the debit and claim counts indicated by the four slot kinds.

Keccak is retained only at this outer commitment boundary because L1 must calculate it. Changing
the source/finality hash to BLAKE2s is independent of this optimization. The compact aggregate changes
the outer verification key and submission ABI, so it requires a new verifier registration.

The reduction removes duplicated calldata and public-input processing; it does not remove the outer
proof's fixed verification cost or the per-chain registry writes. Larger batches amortize those costs.
Production settlement-tree updates are unchanged by this experiment.

## Hash and encoding experiments

The running PoC keeps existing Keccak bundles and trees so that insertion proofs can be tested against
the actual protocol's indexed-Merkle implementation. Separate benchmark variants use compact typed
transfers and alternative commitment hashes. Their formats, measurements, and trust boundaries are in
[`zkip-poc/benchmarks/README.md`](../zkip-poc/benchmarks/README.md).

BLAKE2s is the selected target for shared source and finality commitments. BLAKE3 and Poseidon2 remain
comparison rows. The full BLAKE2s claim measurement assumes a matching settlement hierarchy; the
source-only variant retains the existing Keccak settlement roots.

Changing source IMT hashes requires a source-chain change. Changing the chain/shared settlement trees
also requires a settlement change: today those roots are updated using Keccak on L1. Merely substituting
the Noir hash would authenticate a different root. A future proof-maintained settlement accumulator must
bind accepted batches, chain identities, and L1-authenticated timestamps before an alternative finality
root can replace the current hierarchy.
