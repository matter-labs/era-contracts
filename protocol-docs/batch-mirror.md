# Batch mirror: following a ZKsync OS chain from a chain it does not settle on

`ZKsyncOSBatchMirror` keeps a verified copy of one ZKsync OS chain's executed batches on an EVM chain that
the chain does not settle on, so that the messages the chain sends can be proven there with the standard
`MessageRoot.proveL2MessageInclusionShared`. A typical host is an institution's own EVM ledger following the
institution's ZKsync OS chain, which settles on a shared settlement layer: the ledger acts as a _mirror
settlement layer_ of that chain. Nothing changes for the followed chain or its real settlement layer.

The mirror is verify-only. It never sees the followed chain's priority queue, DA or upgrades; it replays
the settlement layer's own commit and prove calldata and re-runs every check of those steps that does not
depend on the settlement layer's state. The commitment code it uses is the `CommitterFacet`'s own
(`ZKsyncOSBatchCommitment`), so a mirrored batch's `StoredBatchInfo` and its hash are byte-identical to the
settlement layer's.

## Mirroring a range

A validator of the mirror (its relayer) calls `mirrorBatches` with the calldata of one
`proveBatchesSharedBridge` call of the settlement layer, the calldata of each `commitBatchesSharedBridge`
call that committed the proved batches, and the system upgrade transaction hash each batch was committed
with (the settlement layer reports it in `ReportCommittedBatchProtocolVersion`). The mirror:

1. Decodes the proof data with `BatchDecoder` and requires its range to start right after the newest
   mirrored batch and to hold one batch per commit.
2. Requires the proof's previous batch to hash to the newest mirrored batch's stored hash. The first
   range continues from the anchor: the `StoredBatchInfo` the mirror is initialized with, trusted once
   like a genesis.
3. For every commit, decodes it with `BatchDecoder`, requires exactly one batch (as the settlement
   layer's committer does), requires its previous batch to hash to the batch before, and requires its
   `chainId` to be the followed chain, its `slChainId` to be the followed chain's real settlement layer
   (not the mirror's host chain), and its `chainConfigHash` to match the configuration the owner set.
4. Recomputes the batch's `StoredBatchInfo` with `ZKsyncOSBatchCommitment.storedBatchInfo`, as the
   settlement layer's `CommitterFacet` did, and requires the proof's batch to hash to it.
5. Verifies the proof with the configured verifier against the recomputed commitments, exactly the
   public input the settlement layer's `ExecutorFacet` passes. The verifier is called by the mirror, so a
   `MultiProofVerifier` reads the mirror's `disabledProofSystems()`, which the owner keeps equal to the
   followed chain's.
6. Stores each batch's hash and chain batch root, and appends the root to the host chain's `MessageRoot`
   with `addChainBatchRootV32`, as the settlement layer's executor does at execution.

The chain batch root is not a public input of the proof on its own; only the commitment binds it.
Recomputing the commitment from the commit data is what keeps a relayer from mirroring a batch with a
forged root, and with it messages the chain never sent.

The mirror does not re-run the settlement layer's checks that depend on its own state or time: the DA
validator, the DA commitment scheme, the commit timestamp window and priority mode. All of them are about
what the settlement layer accepts, not about what the batch is, and the values they check are in the batch
output hash, which the proof binds.

## What the mirror trusts

With a real verifier, the mirror trusts nobody about whether a batch is a valid state transition of the
followed chain or about the messages in it. A relayer on its own can neither forge a batch nor a message.

It cannot see the settlement layer, so it cannot tell the batch the settlement layer executed from another
valid batch at the same height. Such a batch exists only if the followed chain's own operator produced and
proved two histories, which happens in practice when the settlement layer reverts committed but unexecuted
batches (`revertBatchesSharedBridge`). Choosing the canonical batch is the relayer's job: it must mirror only
batches the settlement layer executed, read at a final block of the settlement layer. The same holds for the
upgrade transaction hash it supplies: a proof binds it, but only the settlement layer knows which upgrade
governance approved. Mirroring is append-only, like execution: a batch that the settlement layer later
reverts cannot be removed from the mirror or from the `MessageRoot`.

Anything stronger needs the settlement layer's state on the host chain, i.e. a light client of the
settlement layer: a storage proof of its `storedBatchHashes(n)` and `totalBatchesExecuted` against a
settlement-layer state root the host chain trusts. Because the mirror's stored hashes are byte-identical to
the settlement layer's, such a check can be added to `mirrorBatches` later without changing what is stored.
It is not cheap on a host chain that has no view of the settlement layer's consensus, so the mirror relies on
the relayer. When the relayer and the mirror's owner belong to the institution that runs the followed chain,
as with an institution's own ledger, that institution relies on nobody but itself.

## Registration in the host chain's Bridgehub

The mirror's batch roots reach the host chain's `MessageRoot` through the same path as a settling chain's.
The host chain runs a Bridgehub and a `MessageRoot`, the mirror is deployed behind a proxy, and the
Bridgehub owner registers it as the followed chain's ZK chain with `registerAlreadyDeployedZKChain`. The
mirror implements the getters that registration reads (`getChainId`, `getChainTypeManager`, `getAdmin`,
`getBaseTokenAssetId`, `getBridgehub`, `getTotalBatchesExecuted`), and the `MessageRoot` registers the chain
at the anchor's batch number, so the first mirrored batch is the next consecutive root. From then on the
mirror is the address `addChainBatchRootV32` accepts for the chain, and proofs need no new code: a message
proof that ends at the chain batch root (`zks_getL2ToL1LogProof` for a chain settling on its settlement layer
directly) is checked against `chainBatchRoots`.

The alternative, a `MessageRoot` extension where an owner names a batch-root source per chain, was rejected.
It changes a core contract shared by L1 and L2 deployments, adds storage and an owner to a contract
that has neither, and still needs the Bridgehub for `addNewChain`. Registering the mirror changes nothing in
the core contracts. It also gives the host chain the same view of the followed chain that a settlement layer
has, which the rest of the interop stack on the host chain (the asset router, the native token vault and the
interop contracts) reads through the Bridgehub as well. The cost is that the Bridgehub owner must register a
chain type manager and the base token asset ID before registering the mirror, and that the registration is
permanent, which is why the mirror sits behind a proxy.

Messages in the anchor batch cannot be proven, since its root is not appended. The mirror is not a diamond, so the
Bridgehub paths that call into a chain's diamond, such as requesting an L2 transaction on the followed chain from the
host chain, revert for it.

## Keeping up with the followed chain

The mirror's owner follows the followed chain's administrative changes; until it does, `mirrorBatches`
reverts:

- `setZKsyncOSChainConfig` when the chain's runtime configuration changes ({protocol-docs/chain-config.md}),
  since every batch commits to it;
- `setVerifier` when the chain's verifier changes in a protocol upgrade;
- `setProofSystemStatus` when the chain's ZiSK switch changes ({protocol-docs/multi-proof-verification.md});
- a proxy upgrade when a protocol upgrade changes the commit or prove encoding or the commitment.
