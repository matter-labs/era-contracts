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

## Cross-chain wrapper experiment

The first larger-window implementation wraps four recursive `agg_4` proofs in `agg_16`. Its first
public field is the recursive child-key commitment, which must match the owner-registered key on L1;
the remaining 32 fields preserve the sixteen statement digests in order. Leaf VK approval and
stale-slot checks still run per statement. Revoking a leaf circuit skips its slots even inside a valid
wrapper. Changing a child key or a statement digest cannot authorize an update.

The same sixteen one-leg statements, spanning four chains and four batches per chain, cost 5,381,067
gas in four separate windows versus 1,735,675 in one wrapped window in the existing warmed call harness
(including calldata and transaction bases). This is a first capacity measurement, not a production fee.
Each proving job stays near the four-proof circuit size; child jobs can be distributed independently.

## Composable proof trees

Sixteen is a benchmark size, not the recursive protocol's capacity. Three additional circuits implement a
common six-field node statement: base-key commitment, fold-key commitment, statement count, tree height,
and the high/low 128-bit halves of an ordered statement-tree root.

- `agg_leaf` verifies four accounting proofs, committing between one and four active statement digests.
- `agg_fold` verifies four base/fold proofs from the same registered key family, commits between one and
  four active child roots, sums their counts, and sets its height to one plus their maximum height.
  Different child heights are allowed. Inactive proof slots repeat a valid child but contribute zero roots.
- `agg_finalize` verifies one base/fold proof and produces an EVM proof with the same six public fields.
  Another aggregator consumes the recursive node directly, without reading any original accounting proofs.

Keys are public parameters rather than embedded recursively in themselves: L1 pins both recursive key
commitments and the final EVM verifier. Each parent hashes the actual child VK, checks it against the
base/fold key selected by the child's height, and checks that the child carries the same key family.
The base circuit fixes height zero, and every active fold edge strictly lowers height.

The leaf statement digest is unchanged. Base/fold tree nodes hash distinct domain tags and four child
hashes with Keccak. L1 receives the ordered statement digests plus a compact postorder shape: tokens
1–4 consume that many statement digests into a zero-padded base, token 0 is a zero padding child, and
128 combines the previous four nodes. L1 reconstructs and authenticates the root before applying any
statements. It then performs the existing current-state digest checks, circuit approvals and independent
stale-slot skipping. Changing an untrusted settlement attachment cannot authorize a different update.
An inclusion mask reports accepted proof inputs, not successful L1 application of all attached statements.

There is no fixed statement window or fixed chain count in this path. Depth is bounded to 30 and the
count to 64 bits (at most 4^31 statements under this arity/depth bound), while actual L1 submissions must
fit transaction gas/calldata limits. Per-statement batch authentication, calldata and state writes remain
linear; only the final proof and its public-input vector are constant size. This is accounting-proof
aggregation, not aggregation of the chains' STF proofs or replacement of production batch settlement.

## Chain admission beyond four chains

The former public four-chain list is replaced by an append-only Poseidon2 Merkle tree of admitted chain
IDs, depth 32. `enableChain` computes the append on L1; it rejects duplicate, zero, out-of-field IDs and
zero chain contracts. There is no owner-supplied root or additional trusted proof. Domain-separated leaves
hash the chain ID, while private membership paths bind both flow source chains to the admitted root.

Claim inputs 9/10 now carry the registry root/count; inputs 11/12 are reserved zeros. The remaining inputs
and the sixteen-field accounting ABI are unchanged. A new registration changes the claim statement and
can make an in-flight claim stale; it can be reproved against the new root. This preserves the prior
list-based behavior and does not disclose the private counterparty to L1. Admission hashing is paid on
registration, not per claim or interop settlement. Poseidon2 is used only for this ZKIP-owned registry;
shared protocol source/finality commitments still target BLAKE2s as described below.

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
